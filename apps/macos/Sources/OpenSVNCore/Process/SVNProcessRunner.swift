import Foundation

/// A fully-resolved process invocation.
///
/// Arguments are always an array: nothing in this type can be interpreted by a
/// shell. See red line R1 in `OpenSVN_开发执行计划.md`.
public struct SVNInvocation: Sendable, Hashable {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectory: URL?
    /// Written to the child's stdin, then stdin is closed. Used for
    /// `--password-from-stdin` so the secret never reaches argv.
    public var standardInput: Data?
    /// Extra environment entries merged over the runner's whitelisted base.
    public var environment: [String: String]
    public var timeout: TimeInterval?

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        standardInput: Data? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.environment = environment
        self.timeout = timeout
    }

    /// Arguments joined for diagnostics. Never includes stdin content.
    public var redactedCommandLine: String {
        ([executableURL.path] + arguments).joined(separator: " ")
    }
}

public struct SVNProcessResult: Sendable, Hashable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var duration: TimeInterval
    public var wasCancelled: Bool
    public var timedOut: Bool
    public var commandLine: String

    public var isSuccess: Bool { exitCode == 0 && !wasCancelled && !timedOut }

    public init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        duration: TimeInterval,
        wasCancelled: Bool = false,
        timedOut: Bool = false,
        commandLine: String = ""
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.duration = duration
        self.wasCancelled = wasCancelled
        self.timedOut = timedOut
        self.commandLine = commandLine
    }
}

/// Runs the `svn` CLI as a child process.
///
/// Guarantees, each of which is a hard requirement from the spec:
/// - argument-array launch (no shell),
/// - both pipes drained concurrently (no 64 KB pipe deadlock on large output),
/// - cooperative cancellation mapped to SIGTERM with a SIGKILL escalation,
/// - enforced timeout,
/// - a fixed locale so XML/date parsing is machine-independent,
/// - a whitelisted environment (in particular, `PATH` is not inherited wholesale).
public struct SVNProcessRunner: Sendable {
    public let executableURL: URL
    /// Environment inherited from the host, filtered to an allow-list.
    public let baseEnvironment: [String: String]
    public let defaultTimeout: TimeInterval?

    /// Variables passed through to the child. `SSH_AUTH_SOCK` is required for
    /// `svn+ssh://` repositories; the rest are needed by svn itself.
    public static let passthroughEnvironmentKeys = [
        "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL",
        "SSH_AUTH_SOCK", "SSL_CERT_FILE", "SSL_CERT_DIR",
        "http_proxy", "https_proxy", "no_proxy",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"
    ]

    /// Locale is pinned so diagnostics and number formatting are stable, but it
    /// must stay UTF-8: with `LC_ALL=C` svn rejects non-ASCII paths with
    /// `E000022: Can't convert string from native encoding to 'UTF-8'`.
    /// XML output itself is locale-independent, so this costs nothing.
    public static let pinnedEnvironment = [
        "LC_ALL": "en_US.UTF-8",
        "LANG": "en_US.UTF-8",
        "LC_CTYPE": "en_US.UTF-8"
    ]

    public init(
        executableURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultTimeout: TimeInterval? = 300
    ) {
        self.executableURL = executableURL
        var filtered: [String: String] = [:]
        for key in Self.passthroughEnvironmentKeys {
            if let value = environment[key], !value.isEmpty {
                filtered[key] = value
            }
        }
        self.baseEnvironment = filtered
        self.defaultTimeout = defaultTimeout
    }

    public func resolvedEnvironment(extra: [String: String]) -> [String: String] {
        var env = baseEnvironment
        env.merge(Self.pinnedEnvironment) { _, pinned in pinned }
        env.merge(extra) { _, new in new }
        return env
    }

    /// Runs the invocation.
    ///
    /// Non-zero exit codes are returned, not thrown: they are normal outcomes
    /// that the service layer maps to a classified `SVNError`. Only launch
    /// failures, cancellation, and timeouts throw.
    public func run(
        _ invocation: SVNInvocation,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> SVNProcessResult {
        let started = Date()
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: invocation.executableURL.path) else {
            throw SVNError(
                code: .svnNotFound,
                message: "找不到可执行的 svn：\(invocation.executableURL.path)"
            )
        }
        if let workingDirectory = invocation.workingDirectory,
           !fileManager.fileExists(atPath: workingDirectory.path) {
            throw SVNError(
                code: .pathNotFound,
                message: "工作目录不存在：\(workingDirectory.path)"
            )
        }

        let execution = ProcessExecution(
            invocation: invocation,
            environment: resolvedEnvironment(extra: invocation.environment),
            onOutputLine: onOutputLine
        )
        execution.startDrains()

        let timeout = invocation.timeout ?? defaultTimeout
        let timeoutTask = makeTimeoutTask(timeout: timeout, session: execution.session)
        defer { timeoutTask?.cancel() }

        let exitCode = await withTaskCancellationHandler {
            await execution.launch()
        } onCancel: {
            execution.session.markCancelled()
            execution.session.terminate()
            Task.detached {
                try? await Task.sleep(for: .seconds(2))
                execution.session.forceKill()
            }
        }

        let output = await execution.finish()
        let stdout = String(decoding: output.stdout, as: UTF8.self)
        let stderr = String(decoding: output.stderr, as: UTF8.self)
        let duration = Date().timeIntervalSince(started)

        if let launchError = execution.launchError {
            if let svnError = launchError as? SVNError { throw svnError }
            throw SVNError(
                code: .svnNotFound,
                message: "无法启动 svn：\(invocation.executableURL.path)",
                diagnosticOutput: LogRedactor.redact(launchError.localizedDescription)
            )
        }

        if execution.session.isCancelled {
            throw SVNError(
                code: .cancelled,
                message: "操作已取消：\(invocation.arguments.first ?? "svn")",
                diagnosticOutput: LogRedactor.redact(stderr),
                exitCode: exitCode
            )
        }
        if execution.session.isTimedOut {
            throw SVNError.timeout(seconds: timeout ?? 0)
        }

        return SVNProcessResult(
            exitCode: exitCode,
            standardOutput: stdout,
            standardError: stderr,
            duration: duration,
            wasCancelled: false,
            timedOut: false,
            commandLine: LogRedactor.redact(invocation.redactedCommandLine)
        )
    }

    private func makeTimeoutTask(timeout: TimeInterval?, session: ProcessSession) -> Task<Void, Never>? {
        guard let timeout, timeout > 0 else { return nil }
        return Task.detached {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard session.process.isRunning else { return }
            session.markTimedOut()
            session.terminate()
            try? await Task.sleep(for: .seconds(2))
            session.forceKill()
        }
    }
}

// MARK: - One process execution

/// Owns the process, its pipes, and the drains for a single invocation.
/// Reference type because the same instance is touched from the caller's task
/// and from dispatch queues owned by the read sources.
final class ProcessExecution: @unchecked Sendable {
    let session = ProcessSession()
    let invocation: SVNInvocation
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let drainJoin = DrainJoin(count: 2)
    private let exitWaiter = ExitWaiter()
    /// Strong references are mandatory: the read sources only hold weak
    /// references back to their drain, so releasing these would leave the
    /// continuation waiting forever for an EOF that nobody reports.
    private var drains: [PipeDrain] = []
    private let onOutputLine: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var launchErrorStorage: (any Error)?

    init(
        invocation: SVNInvocation,
        environment: [String: String],
        onOutputLine: (@Sendable (String) -> Void)?
    ) {
        self.invocation = invocation
        self.onOutputLine = onOutputLine
        let process = session.process
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    var launchError: (any Error)? {
        lock.lock(); defer { lock.unlock() }
        return launchErrorStorage
    }

    private func setLaunchError(_ error: any Error) {
        lock.lock(); launchErrorStorage = error; lock.unlock()
    }

    func startDrains() {
        let stdoutDrain = PipeDrain(
            handle: stdoutPipe.fileHandleForReading,
            label: "opensvn.svn.stdout",
            onLine: onOutputLine
        ) { [drainJoin] data in
            drainJoin.finish(index: 0, data: data)
        }
        let stderrDrain = PipeDrain(
            handle: stderrPipe.fileHandleForReading,
            label: "opensvn.svn.stderr",
            onLine: nil
        ) { [drainJoin] data in
            drainJoin.finish(index: 1, data: data)
        }
        stdoutDrain.start()
        stderrDrain.start()
        drains = [stdoutDrain, stderrDrain]
    }

    /// Runs the process and returns its exit code.
    ///
    /// Parent-side write ends are closed *immediately* after the child is
    /// spawned — before waiting for exit — so the child never blocks on a
    /// stdin that the parent still holds open. Doing this after the wait is a
    /// deadlock whenever svn reads stdin.
    func launch() async -> Int32 {
        if session.isCancelled {
            setLaunchError(SVNError.cancelled())
            closeParentPipeEnds()
            return -1
        }

        _ = ProcessSignals.ignoreSIGPIPE
        session.process.terminationHandler = { [exitWaiter] finished in
            exitWaiter.complete(finished.terminationStatus)
        }

        do {
            try session.process.run()
        } catch {
            setLaunchError(error)
            closeParentPipeEnds()
            return -1
        }

        closeParentPipeEnds()

        if !session.isCancelled, let input = invocation.standardInput {
            // If the child already exited, this write gets EPIPE; SIGPIPE is
            // ignored process-wide so it cannot take the app down.
            try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
        }
        try? stdinPipe.fileHandleForWriting.close()

        return await exitWaiter.wait()
    }

    func finish() async -> (stdout: Data, stderr: Data) {
        let output = await drainJoin.wait()
        return (output[0] ?? Data(), output[1] ?? Data())
    }

    private func closeParentPipeEnds() {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        if launchError != nil {
            try? stdinPipe.fileHandleForWriting.close()
        }
    }
}

/// One-shot exit-code handoff that cannot lose a completion that happens
/// before the waiter arrives.
final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func complete(_ code: Int32) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: code)
        } else {
            self.code = code
            lock.unlock()
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let code {
                lock.unlock()
                continuation.resume(returning: code)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Process-wide signal dispositions this runner depends on.
enum ProcessSignals {
    /// Writing to a pipe whose reader has exited must fail with EPIPE instead
    /// of terminating the process. Every GUI app that spawns children wants
    /// this; Foundation does not do it for us.
    static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
}

// MARK: - Process session

/// `Process` is not `Sendable`; this box serialises the few cross-thread reads
/// and writes we need (cancellation state, signal delivery).
final class ProcessSession: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelledFlag = false
    private var timedOutFlag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    var isTimedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOutFlag
    }

    func markCancelled() {
        lock.lock(); cancelledFlag = true; lock.unlock()
    }

    func markTimedOut() {
        lock.lock(); timedOutFlag = true; lock.unlock()
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func forceKill() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

// MARK: - Pipe draining

/// Drains one pipe with a `DispatchSourceRead`, so neither a full stdout nor a
/// full stderr pipe can block the child.
final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let onLine: (@Sendable (String) -> Void)?
    private let onFinish: @Sendable (Data) -> Void
    /// Complete output. Kept separately from `buffer` because streaming to
    /// `onLine` consumes the line buffer, and progress consumers must not
    /// change what the caller receives.
    private var collected = Data()
    private var buffer = Data()
    private var source: DispatchSourceRead?

    init(
        handle: FileHandle,
        label: String,
        onLine: (@Sendable (String) -> Void)?,
        onFinish: @escaping @Sendable (Data) -> Void
    ) {
        self.handle = handle
        self.queue = DispatchQueue(label: label)
        self.onLine = onLine
        self.onFinish = onFinish
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = self.handle.availableData
            guard !data.isEmpty else {
                source.cancel()
                return
            }
            self.buffer.append(data)
            self.collected.append(data)
            if self.onLine != nil {
                self.emitLines(final: false)
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.onLine != nil {
                self.emitLines(final: true)
            }
            let payload = self.collected
            self.buffer.removeAll()
            self.collected.removeAll()
            self.onFinish(payload)
            try? self.handle.close()
        }
        source.resume()
    }

    private func emitLines(final: Bool) {
        guard let onLine else { return }
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            onLine(String(decoding: lineData, as: UTF8.self))
        }
        if final, !buffer.isEmpty {
            onLine(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
    }
}

/// Joins two drain completions into one awaitable value.
final class DrainJoin: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var outputs: [Int: Data] = [:]
    private var waiter: CheckedContinuation<[Int: Data], Never>?

    init(count: Int) {
        self.remaining = count
    }

    func finish(index: Int, data: Data) {
        lock.lock()
        outputs[index] = data
        remaining -= 1
        if remaining == 0, let waiter {
            self.waiter = nil
            let snapshot = outputs
            lock.unlock()
            waiter.resume(returning: snapshot)
        } else {
            lock.unlock()
        }
    }

    func wait() async -> [Int: Data] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if remaining == 0 {
                let snapshot = outputs
                lock.unlock()
                continuation.resume(returning: snapshot)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
