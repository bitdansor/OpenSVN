import SwiftUI
import OpenSVNCore

struct CredentialSheet: View {
    @Environment(AppState.self) private var appState
    let host: String
    let errorMessage: String?

    @State private var username = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("需要认证")
                        .font(.headline)
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Form {
                TextField("用户名", text: $username)
                    .focused($focusedField, equals: .username)
                SecureField("密码", text: $password)
                    .focused($focusedField, equals: .password)
            }
            .textFieldStyle(.roundedBorder)

            Text("凭据只保存在 macOS 钥匙串。密码通过标准输入传给 svn，不会出现在命令行参数中。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { appState.cancelCredentialPrompt() }
                    .keyboardShortcut(.cancelAction)
                Button("登录") {
                    appState.submitCredential(username: username, password: password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { focusedField = .username }
    }
}

struct CheckoutSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var destination = NSHomeDirectory() + "/OpenSVN"
    @State private var depth: SVNService.CheckoutDepth = .infinity
    @State private var revisionText = ""
    @State private var storePristines = true
    @State private var isRunning = false
    @State private var errorMessage: String?

    /// Pristines on Demand needs svn 1.15; before that the option does not exist
    /// and opting in rewrites the working copy to a format older clients cannot
    /// open. The service refuses it — this only keeps the UI from offering it.
    private var supportsPristinesOnDemand: Bool {
        guard let version = appState.installation?.version else { return false }
        return version >= SVNService.pristineStoreMinimumVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("检出仓库")
                .font(.headline)

            Form {
                TextField("仓库 URL", text: $url, prompt: Text("https://example.com/svn/trunk"))
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField("目标目录", text: $destination)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { chooseDestination() }
                }

                Picker("检出深度", selection: $depth) {
                    ForEach(SVNService.CheckoutDepth.allCases, id: \.self) { depth in
                        Text(depth.displayName).tag(depth)
                    }
                }

                TextField("修订版本（可选）", text: $revisionText, prompt: Text("留空表示 HEAD"))
                    .textFieldStyle(.roundedBorder)

                Toggle("不保存原始副本，按需从仓库获取（--store-pristine=no）", isOn: $storePristines)
                    .toggleStyle(.checkbox)
                    .disabled(!supportsPristinesOnDemand)
            }

            Text(pristinesNote)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("检出在后台执行，可在任务中心查看进度或取消。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRunning ? "检出中…" : "检出") {
                    Task { await checkout() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || url.isEmpty || destination.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: supportsPristinesOnDemand) { _, supported in
            if !supported { storePristines = true }
        }
    }

    private var pristinesNote: String {
        guard supportsPristinesOnDemand else {
            return "按需获取原始副本需要 svn 1.15 或更高版本；当前 \(appState.installation?.version.description ?? "未知版本")，因此该选项不可用。"
        }
        return "关闭后工作副本不再本地保存原始副本，磁盘占用更小，但格式会升级到 32：svn 1.14 及更旧客户端将无法打开这个工作副本，且无法降级。"
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择检出目标目录（可为空目录）"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        destination = chosen.appendingPathComponent(url.split(separator: "/").last.map(String.init) ?? "checkout").path
    }

    private func checkout() async {
        isRunning = true
        defer { isRunning = false }
        errorMessage = nil
        do {
            try await appState.checkout(
                url: url.trimmingCharacters(in: .whitespaces),
                destination: URL(fileURLWithPath: destination),
                depth: depth,
                revision: Int64(revisionText.trimmingCharacters(in: .whitespaces)),
                storePristines: storePristines
            )
            dismiss()
        } catch let error as SVNError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
