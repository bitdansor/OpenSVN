import Foundation

/// Builds a throwaway repository plus a working copy that already contains
/// conflicts, so the merge editor can be tried without first finding a
/// repository of one's own.
///
/// Three constraints shape this type:
///
/// - **Nothing outside the demo folder is touched.** The folder carries a marker
///   file. If the target exists without that marker, the build refuses instead of
///   deleting files it did not create. A "generate sample" command that can eat a
///   user's Documents folder is not a feature.
/// - **No network.** The repository is `file://` on the local disk, so the demo
///   works offline and cannot leak anything.
/// - **The conflict mix is deliberate.** A demo where every file conflicts
///   teaches the wrong lesson: three-way merge is mostly automatic. The generated
///   tree has text conflicts that need a decision, regions that merge silently,
///   one file that only the server changed, and one property conflict that
///   *cannot* be three-way merged — so the guide can explain the difference
///   instead of asserting it.
public struct DemoWorkspace: Sendable {
    public struct Result: Sendable, Hashable {
        public let workingCopy: URL
        public let repository: URL

        public init(workingCopy: URL, repository: URL) {
            self.workingCopy = workingCopy
            self.repository = repository
        }
    }

    public enum Step: String, Sendable, CaseIterable {
        case preparing
        case creatingRepository
        case importing
        case checkingOut
        case committingServer
        case creatingConflicts
        case verifying

        public var title: String {
            switch self {
            case .preparing: return "准备演示目录"
            case .creatingRepository: return "创建本地仓库"
            case .importing: return "导入示例文件"
            case .checkingOut: return "检出工作副本"
            case .committingServer: return "提交服务器端的改动"
            case .creatingConflicts: return "制造冲突"
            case .verifying: return "校验冲突"
            }
        }
    }

    /// Folder name under the home directory. Deliberately readable and obviously
    /// disposable: the user must be able to delete it without wondering what it
    /// belongs to.
    public static let folderName = "OpenSVN 合并演示"

    /// Written into the demo folder. Its absence is what makes the build refuse
    /// to touch an existing directory.
    public static let markerName = ".opensvn-demo"

    /// `~/Documents` is the natural home for this, but macOS guards Desktop,
    /// Documents and Downloads with a TCC prompt. A feature whose first action is
    /// a system permission dialog teaches the user to click "allow" without
    /// reading, so the demo lives one level up — visible in Finder, not guarded.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public static var defaultWorkingCopy: URL {
        defaultRoot.appendingPathComponent("工作副本", isDirectory: true)
    }

    /// `svnadmin` is not part of `SVNInstallation` — the app never needs it for
    /// normal work. It ships next to `svn` in every distribution layout we
    /// support (Homebrew, MacPorts, the official binaries), so looking beside the
    /// resolved executable is exact rather than a PATH guess.
    public static func adminTool(nextTo svn: URL) -> URL? {
        let candidate = svn.deletingLastPathComponent().appendingPathComponent("svnadmin")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    public let root: URL
    public let svn: URL
    public let svnadmin: URL

    public init(root: URL = DemoWorkspace.defaultRoot, svn: URL, svnadmin: URL) {
        self.root = root
        self.svn = svn
        self.svnadmin = svnadmin
    }

    public var repositoryURL: URL { root.appendingPathComponent("repo", isDirectory: true) }
    public var workingCopyURL: URL { root.appendingPathComponent("工作副本", isDirectory: true) }
    private var serverCopyURL: URL { root.appendingPathComponent(".demo-server", isDirectory: true) }
    private var seedURL: URL { root.appendingPathComponent("seed", isDirectory: true) }

    // MARK: - Build

    public func build(onStep: @escaping @MainActor @Sendable (Step) -> Void = { _ in }) async throws -> Result {
        try prepareDirectory()
        await onStep(.preparing)

        try writeSeed()

        await onStep(.creatingRepository)
        try await run(svnadmin, ["create", repositoryURL.path], during: .creatingRepository)

        await onStep(.importing)
        let repoURL = "file://\(repositoryURL.path)"
        try await run(
            svn,
            ["import", seedURL.path, repoURL, "-m", "初始导入：合并演示", "--no-auth-cache", "--non-interactive"],
            during: .importing
        )

        await onStep(.checkingOut)
        let trunkURL = "\(repoURL)/trunk"
        try await run(
            svn,
            ["checkout", trunkURL, workingCopyURL.path, "--no-auth-cache", "--non-interactive"],
            during: .checkingOut
        )
        try await run(
            svn,
            ["checkout", trunkURL, serverCopyURL.path, "--no-auth-cache", "--non-interactive"],
            during: .checkingOut
        )

        // The server side has to land first: a conflict is "my edit against an
        // edit that already reached the repository".
        await onStep(.committingServer)
        try writeServerEdits()
        try await run(
            svn,
            ["commit", serverCopyURL.path, "-m", "服务器：修改 subtract、multiply、config 与日志级别", "--no-auth-cache", "--non-interactive"],
            during: .committingServer
        )

        await onStep(.creatingConflicts)
        try writeLocalEdits()
        try await run(
            svn,
            ["propset", "custom:owner", "本地团队", local("docs/属性冲突.txt")],
            during: .creatingConflicts
        )
        try await run(
            svn,
            ["propset", "custom:owner", "服务器团队", server("docs/属性冲突.txt")],
            during: .creatingConflicts
        )
        try await run(
            svn,
            ["commit", serverCopyURL.path, "-m", "服务器：属性评审人设为服务器团队", "--no-auth-cache", "--non-interactive"],
            during: .committingServer
        )

        // Conflicts are the expected outcome here, so a non-zero exit is not an
        // error. What matters is verified below.
        _ = try await runAllowingFailure(
            svn,
            ["update", workingCopyURL.path, "--non-interactive", "--no-auth-cache"],
            during: .creatingConflicts
        )

        await onStep(.verifying)
        try await verifyConflicts()
        try tidyUp()

        return Result(workingCopy: workingCopyURL, repository: repositoryURL)
    }

    /// True when a previous build produced a working copy that is still a working
    /// copy — used by the guide sheet to offer "open the existing demo".
    public var existingWorkingCopy: URL? {
        let path = DemoWorkspace.defaultWorkingCopy
        return WorkingCopyLocator.isWorkingCopy(path) ? path : nil
    }

    // MARK: - Filesystem

    private func prepareDirectory() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.path) {
            let marker = root.appendingPathComponent(Self.markerName)
            let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
            if !fileManager.fileExists(atPath: marker.path), !contents.isEmpty {
                throw SVNError(
                    code: .permissionDenied,
                    message: "「\(root.lastPathComponent)」已存在，且不是 OpenSVN 演示目录。为免覆盖你自己的文件，已停止。请换一个位置，或先把它移走。"
                )
            }
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try "此目录由 OpenSVN 生成，仅用于体验合并，可随时整体删除。\n"
            .write(to: root.appendingPathComponent(Self.markerName), atomically: true, encoding: .utf8)

        // Only the entries this builder owns are removed; a stray file the user
        // dropped into the folder survives.
        for url in [repositoryURL, workingCopyURL, seedURL, serverCopyURL] {
            try? fileManager.removeItem(at: url)
        }
    }

    private func local(_ relative: String) -> String {
        workingCopyURL.appendingPathComponent(relative).path
    }

    private func server(_ relative: String) -> String {
        serverCopyURL.appendingPathComponent(relative).path
    }

    private func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeSeed() throws {
        try write(Self.readmeText, at: seedURL.appendingPathComponent("trunk/README.md"))
        try write(Self.calculatorBase, at: seedURL.appendingPathComponent("trunk/src/calculator.swift"))
        try write(Self.utilBase, at: seedURL.appendingPathComponent("trunk/src/util.swift"))
        try write(Self.configBase, at: seedURL.appendingPathComponent("trunk/docs/config.md"))
        try write(Self.releaseNotesBase, at: seedURL.appendingPathComponent("trunk/docs/发布说明.md"))
        try write(Self.propertyDemoBase, at: seedURL.appendingPathComponent("trunk/docs/属性冲突.txt"))
        for directory in ["branches", "tags"] {
            try FileManager.default.createDirectory(
                at: seedURL.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
    }

    private func writeServerEdits() throws {
        try write(Self.calculatorTheirs, at: URL(fileURLWithPath: server("src/calculator.swift")))
        try write(Self.utilTheirs, at: URL(fileURLWithPath: server("src/util.swift")))
        try write(Self.configTheirs, at: URL(fileURLWithPath: server("docs/config.md")))
        try write(Self.releaseNotesTheirs, at: URL(fileURLWithPath: server("docs/发布说明.md")))
    }

    private func writeLocalEdits() throws {
        try write(Self.calculatorMine, at: URL(fileURLWithPath: local("src/calculator.swift")))
        try write(Self.configMine, at: URL(fileURLWithPath: local("docs/config.md")))
        try write(Self.releaseNotesMine, at: URL(fileURLWithPath: local("docs/发布说明.md")))
    }

    /// Removes the scaffolding. Leaving a second checkout named `.demo-server`
    /// around would only make "add working copy" ambiguous.
    private func tidyUp() throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: seedURL)
        try? fileManager.removeItem(at: serverCopyURL)
    }

    // MARK: - Verification

    /// A demo that silently produced no conflicts would send the user looking at
    /// a working copy where nothing can be tried. Assert the point of the
    /// exercise instead of assuming it.
    private func verifyConflicts() async throws {
        let result = try await runAllowingFailure(
            svn,
            ["status", "--xml", workingCopyURL.path, "--no-auth-cache", "--non-interactive"],
            during: .verifying
        )
        guard result.exitCode == 0 else {
            throw SVNError(
                code: .commandFailed(exitCode: result.exitCode),
                message: "无法读取演示工作副本的状态：\(Self.diagnostic(result))"
            )
        }
        let conflicts = result.standardOutput.components(separatedBy: "conflicted").count - 1
        guard conflicts >= 3 else {
            throw SVNError(
                code: .unknown,
                message: "演示工作副本只生成了 \(conflicts) 处冲突（预期至少 3 处）。请删除「\(root.lastPathComponent)」后重试。"
            )
        }
    }

    // MARK: - Process

    private func run(_ tool: URL, _ arguments: [String], during step: Step) async throws {
        let result = try await runAllowingFailure(tool, arguments, during: step)
        guard result.exitCode == 0 else {
            throw SVNError(
                code: .commandFailed(exitCode: result.exitCode),
                message: "\(step.title)失败：\(Self.diagnostic(result))"
            )
        }
    }

    private func runAllowingFailure(
        _ tool: URL,
        _ arguments: [String],
        during _: Step
    ) async throws -> SVNProcessResult {
        let runner = SVNProcessRunner(executableURL: tool, defaultTimeout: 120)
        return try await runner.run(
            SVNInvocation(
                executableURL: tool,
                arguments: arguments,
                workingDirectory: root,
                environment: [:],
                timeout: 120
            )
        )
    }

    private static func diagnostic(_ result: SVNProcessResult) -> String {
        let text = result.standardError.isEmpty ? result.standardOutput : result.standardError
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "退出码 \(result.exitCode)" : trimmed
    }

    // MARK: - Sample content
    //
    // The files are written to make one specific lesson visible: only the region
    // both sides touched needs a decision. Each file states that lesson in a
    // comment where the user will read it, because the demo is also the
    // documentation.

    static let readmeText = """
    # OpenSVN 合并演示

    这个仓库由 OpenSVN 生成，只用来体验「三方合并」。整个文件夹可以随时删除。

    ## 里面有什么

    | 文件 | 会看到什么 |
    |---|---|
    | `src/calculator.swift` | 3 处自动合并，1 处需要你决定 |
    | `docs/config.md` | 2 处自动合并，1 处需要你决定 |
    | `docs/发布说明.md` | 中文文件名，2 处自动合并，1 处需要你决定 |
    | `docs/属性冲突.txt` | 只有属性冲突，三方合并处理不了 |
    | `src/util.swift` | 只有服务器改过，更新时已经自动合并 |

    ## 怎么试

    1. 在 OpenSVN 的「变更」页顶部点「开始三方合并」。
    2. 每处冲突对比「我的 / 基线 / 服务器」，选一边。
    3. 点「写入并标记已解决」，然后刷新状态。

    两类改动会**自动合并、不用你动手**：只有一边改过的地方。真正需要决定的是
    两边改了同一处、而且改得不一样的地方。

    """

    static let calculatorBase = """
    // 计算器：一个用来演示三方合并的小模块

    func add(_ a: Int, _ b: Int) -> Int {
        return a + b
    }

    func subtract(_ a: Int, _ b: Int) -> Int {
        return a - b
    }

    func multiply(_ a: Int, _ b: Int) -> Int {
        return a * b
    }

    """

    static let calculatorMine = """
    // 计算器：本地版本（这处注释只有我改，会自动采用）

    func add(_ a: Int, _ b: Int) -> Int {
        return a + b
    }

    func subtract(_ a: Int, _ b: Int) -> Int {
        return a - b
    }

    func multiply(_ a: Int, _ b: Int) -> Int {
        return a * b  // 本地：先走快速路径
    }

    func divide(_ a: Int, _ b: Int) -> Int? {
        return b == 0 ? nil : a / b
    }

    """

    static let calculatorTheirs = """
    // 计算器：一个用来演示三方合并的小模块

    func add(_ a: Int, _ b: Int) -> Int {
        return a + b
    }

    func subtract(_ a: Int, _ b: Int) -> Int {
        // 服务器：避免 -0 出现在输出里
        let result = a - b
        return result == 0 ? 0 : result
    }

    func multiply(_ a: Int, _ b: Int) -> Int {
        // 服务器：任意一边为 0 时直接短路
        if a == 0 || b == 0 { return 0 }
        return a * b
    }

    """

    static let utilBase = """
    func clamp(_ value: Int, min lower: Int, max upper: Int) -> Int {
        return value
    }

    """

    static let utilTheirs = """
    func clamp(_ value: Int, min lower: Int, max upper: Int) -> Int {
        return Swift.min(Swift.max(value, lower), upper)
    }

    """

    static let configBase = """
    # 服务配置

    ## 超时

    请求超时时间为 30 秒。

    ## 重试

    失败后重试 2 次。

    ## 日志

    日志级别为 info。

    """

    static let configMine = """
    # 服务配置

    ## 超时

    请求超时时间为 60 秒。

    ## 重试

    失败后重试 3 次。

    ## 日志

    日志级别为 info。

    """

    static let configTheirs = """
    # 服务配置

    ## 超时

    请求超时时间为 45 秒。

    ## 重试

    失败后重试 2 次。

    ## 日志

    日志级别为 debug。

    """

    static let releaseNotesBase = """
    # 版本 0.1.0

    - 支持检出、更新、提交
    - 支持中文路径

    """

    static let releaseNotesMine = """
    # 版本 0.2.0

    - 支持检出、更新、提交
    - 支持三方合并（本地新增）
    - 支持中文路径

    """

    static let releaseNotesTheirs = """
    # 版本 0.1.1

    - 支持检出、更新、提交
    - 支持中文路径
    - 修复提交后状态不刷新（服务器新增）

    """

    static let propertyDemoBase = """
    这个文件的内容两边都没改，只改了属性 custom:owner。
    属性冲突不能三方合并：需要整体选一边。

    """
}
