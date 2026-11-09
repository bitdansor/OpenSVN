import Foundation

/// English for the Settings window and the extensions sheet.
///
/// The explanatory footers are the bulk of it. They are translated at the same
/// length as the Chinese: a footer that shrinks to one clause in English loses
/// the "why", which is the entire reason it is there.
enum StringsSettings {
    static let table: [String: String] = [
        // MARK: - Panes and tabs

        "行为": "Behaviour",
        "通用": "General",
        "界面语言": "Interface language",
        "跟随系统": "Follow System",
        // `简体中文` is deliberately absent: the picker names each language in
        // that language, so it reads the same in both interfaces.
        "跟随系统会使用 macOS 的语言设置：系统语言是中文时显示中文，其他语言显示英文。手动选择后立即生效，不需要重新启动。":
            "Follow System uses the macOS language setting: a Chinese system gets the Chinese interface, anything else gets English. A manual choice applies immediately and survives relaunch.",
        "工具": "Tools",
        "凭据": "Credentials",
        "连接": "Connection",
        "关于": "About",
        "执行": "Execution",
        "诊断": "Diagnostics",

        // MARK: - SVN runtime pane

        "可执行文件": "Executable",
        "选择…": "Choose…",
        "清除": "Clear",
        "当前使用": "In use",
        "svn 运行时": "SVN runtime",
        "自动刷新（监听文件变化）": "Refresh automatically (watch for changes)",
        "更新前先查看服务器上的变更": "Review the server's changes before updating",
        "刷新与更新": "Refresh and update",
        "自动刷新只监听当前打开的工作副本，.svn 内部的改动会被忽略——否则每次刷新都会触发下一次刷新。更新前预览多花一次网络往返，换回一份「将要发生什么」的清单。":
            "Automatic refresh watches only the working copy you have open, and ignores changes inside `.svn` — otherwise every refresh would trigger the next one. Previewing before an update costs one extra round trip and buys a list of what is about to happen.",
        "启动时检查新版本": "Check for updates at launch",
        "发现新版本时自动下载": "Download new versions automatically",
        "正在检查…": "Checking…",
        "手动检查": "Check now",
        "检查更新…": "Check for Updates…",
        "版本": "Version",
        "启动时检查默认关闭：这是本应用唯一会主动连接项目服务器的请求（GitHub 的 Releases 接口），只读取公开的版本信息，不携带任何本机数据，每天最多一次。关了也不影响菜单里的「检查更新…」。自动下载只在启动检查开启时生效，而且只下载可校验的安装包；安装仍需你点「重新启动并安装」。可校验有两种方式：发布清单由本项目的 Ed25519 密钥签名（免费，也是本项目发布所用的方式），或更新包带与当前应用相同的 Developer ID 团队签名。两者都没有时会拒绝自动安装，只给下载链接。":
            "The launch check is off by default: it is the only request this app makes to the project's servers (GitHub's Releases API), it reads public version information only, carries no data about this Mac, and happens at most once a day. Turning it off does not affect “Check for Updates…” in the menu. Automatic download applies only while the launch check is on, and only to installers that can be verified — installation still needs you to press “Relaunch and Install”. Verification works two ways: the release manifest is signed with the project's Ed25519 key (free, and what this project publishes), or the update carries the same Developer ID team signature as the running app. With neither, automatic installation is refused and you get a download link instead.",
        "尚未检测到可用的 svn": "No usable svn detected yet",
        "留空则按「应用内置 → PATH → 常见位置」的顺序查找——从 Finder 启动的应用不继承 Homebrew 的 PATH，所以显式路径优先。":
            "Leave it empty to search in the order bundled → PATH → standard locations. An app launched from Finder does not inherit Homebrew's PATH, which is why an explicit path wins.",

        // MARK: - Behaviour pane

        "单次操作超时": "Timeout per operation",
        "秒": "seconds",
        "同时进行的写操作": "Concurrent write operations",
        "%@ 个": "%@",
        "危险操作前要求确认": "Ask before destructive operations",
        "任务成功 / 失败时发送通知": "Notify when a task succeeds or fails",
        "确认在服务层强制执行，这个开关只决定界面是否提前展示预览。写操作上限约束的是不同工作副本之间的并行度——同一个工作副本上的两个写操作始终排队，与上限无关。任务通知在任务中心的任务成功或失败时发送本地通知；未签名或未获通知授权时会自动跳过。":
            "Confirmation is enforced in the service layer; this switch only controls whether the UI shows a preview up front. The write limit caps parallelism across different working copies — two writes on the same working copy always queue, regardless of the limit. Task notifications are posted when a task in the task centre finishes; they are skipped silently when the build is unsigned or authorisation was never granted.",
        "当前使用 %@。": "Currently using %@.",
        "选择": "Choose",
        "选择 svn 可执行文件": "Choose the svn executable",

        // MARK: - Tools pane

        "外部 diff 命令": "External diff command",
        "外部 diff": "External diff",
        "留空则使用内置差异视图。填了会传给 svn diff --diff-cmd，应填包装脚本而不是 GUI 程序本身：svn 会等子进程退出，直接指向 GUI 会让操作卡到窗口关闭为止。":
            "Leave it empty to use the built-in diff view. Anything set here is passed to `svn diff --diff-cmd`, and it should be a wrapper script rather than a GUI program: svn waits for the child to exit, so pointing it at a GUI blocks the operation until that window closes.",
        "URL 模板": "URL template",
        "工单链接": "Ticket links",
        "识别 #123、PROJ-123、issue 123，生成可点击链接。占位符可用 {id}、{number}、{key}。":
            "Turns #123, PROJ-123 and issue 123 into clickable links. Placeholders: {id}, {number}, {key}.",
        "参数模板": "Argument template",
        "外部合并": "External merge",
        "命令按参数数组执行，不使用 shell 字符串拼接。占位符：{base}、{mine}、{theirs}、{merged}、{file}。":
            "The command runs from an argument array, never a shell string. Placeholders: {base}, {mine}, {theirs}, {merged}, {file}.",
        "记录级别": "Log level",
        "日志文件夹": "Log folder",
        "打开": "Open",
        "日志": "Logging",
        "选择用于 svn diff 的脚本或程序": "Choose the script or program used for svn diff",
        "%@ 超过 2 MB 自动轮转，最多保留 2 个旧文件；凭据在写入前统一脱敏。":
            "%@ rotates at 2 MB and keeps at most two older files; credentials are redacted before anything is written.",
        "选择外部合并工具": "Choose an external merge tool",

        // MARK: - Credentials pane

        "钥匙串中没有保存的仓库密码。": "No repository passwords are saved in the Keychain.",
        "认证域：%@": "Authentication realm: %@",
        "删除 %@ 的已保存密码，下次访问时需要重新输入":
            "Delete the saved password for %@; you will be asked again next time",
        "清除全部凭据…": "Clear All Credentials…",
        "已保存的密码": "Saved passwords",
        "密码保存在 macOS 钥匙串，不会写入配置、日志或命令行参数。删除后只影响本机，不影响服务器上的账号。":
            "Passwords live in the macOS Keychain and are never written to settings, logs or command-line arguments. Deleting one affects this Mac only, never the account on the server.",
        "清除所有已保存的仓库凭据？": "Clear every saved repository credential?",
        "取消": "Cancel",
        "下次访问需要认证的仓库时需要重新输入用户名与密码。":
            "You will have to type the username and password again the next time you open a repository that needs authentication.",

        // MARK: - Connection pane

        "临时放宽证书校验？": "Relax certificate checks for one connection?",
        "仍要连接（仅此一次）": "Connect Anyway (once)",
        "仅对紧接着的一次 svn 操作生效，之后自动恢复为上方的策略。svn 在 --non-interactive 模式下不会逐张证书询问，本次操作将静默接受带有这些问题的证书。请确认你信任目标服务器。":
            "Applies to the next svn operation only, then the policy above takes over again. Under `--non-interactive` svn cannot ask per certificate, so this one operation silently accepts certificates with the problems listed. Make sure you trust the server.",
        "修改 ~/.subversion/servers？": "Modify ~/.subversion/servers?",
        "备份并保存": "Back Up and Save",
        "保存前会先把现有文件备份为 servers.opensvn-backup-<时间戳>，只改动 [global] 段中的 4 个代理字段，其余内容与注释保持不变。该文件是 svn 的全局配置，会影响使用此用户目录的所有 svn 客户端。":
            "The existing file is backed up as `servers.opensvn-backup-<timestamp>` first. Only the four proxy fields in the `[global]` section change; every other line and comment is left as it is. This file is svn's global configuration and affects every svn client using this home folder.",
        "证书校验": "Certificate verification",
        "严格校验（推荐）": "Strict (recommended)",
        "信任指定问题": "Trust specific problems",
        "信任所有未知证书（高风险）": "Trust all unknown certificates (high risk)",
        "失败类型（同时用于一次性的「仍要连接」）：":
            "Failure types (also used by the one-off “Connect Anyway”):",
        "将下发全部 5 种失败类型，接受任何未知、过期或域名不匹配的证书。":
            "All five failure types are passed, accepting any certificate that is unknown, expired or issued for another host.",
        "HTTPS 服务器证书": "HTTPS server certificates",
        "默认严格校验：遇到无效证书时 svn 会直接失败。勾选失败类型后，svn 会在 --non-interactive 下静默接受对应问题的证书——攻击者可借此冒充服务器、窃取或篡改提交内容。仅在你确认是自签名/内网证书时启用，并尽量只勾选一项。本应用改用全量 --trust-server-cert-failures（可填 unknown-ca / cn-mismatch / expired / not-yet-valid / other 的逗号组合）：旧参数 --trust-server-cert 已废弃、仅等价于 unknown-ca，且可能往 stderr 打警告污染错误分类，因此不会下发。该选项仅在 svn 1.14 及以上生效，旧版本自动保持严格校验。":
            "Strict by default: svn fails outright on an invalid certificate. Once a failure type is ticked, svn silently accepts certificates with that problem under `--non-interactive` — which is exactly how an attacker can impersonate the server and read or alter what you commit. Enable it only when you know the certificate is self-signed or internal, and tick as few types as possible. This app uses the full `--trust-server-cert-failures` (a comma-separated mix of unknown-ca / cn-mismatch / expired / not-yet-valid / other): the older `--trust-server-cert` flag is deprecated, only ever means unknown-ca, and can write a warning to stderr that muddies error classification, so it is never passed. The option only takes effect on svn 1.14 and later; older versions stay strict.",
        "为下一次连接临时放宽…": "Relax for the next connection…",
        "已就绪，等待下一次连接": "Ready; waiting for the next connection",
        "请先在上方勾选至少一种失败类型。":
            "Tick at least one failure type above first.",
        "一次性的「仍要连接」": "The one-off “Connect Anyway”",
        "「仍要连接」不会永久降低校验强度：它使用上方勾选的失败类型，只对紧接着的一次 svn 操作生效，操作后自动清除。适用于偶发的内网自签名证书，避免把宽松策略长期留在设置里。":
            "“Connect Anyway” never weakens verification permanently: it reuses the failure types ticked above, applies to the next svn operation only, and clears itself afterwards. It is there for the occasional internal self-signed certificate, so a relaxed policy does not have to live in Settings.",
        "配置文件": "Configuration file",
        "当前代理（只读）": "Current proxy (read-only)",
        "该文件尚不存在，保存代理设置时会新建。":
            "The file does not exist yet; saving proxy settings will create it.",
        "主机": "Host",
        "端口": "Port",
        "用户名": "Username",
        "排除列表": "Exceptions",
        "保存代理设置…": "Save Proxy Settings…",
        "代理（~/.subversion/servers）": "Proxy (~/.subversion/servers)",
        "http-proxy-password 不在此处编辑：明文写进共享配置文件会抵消钥匙串的保护。保存前会自动备份原文件，且只改动 [global] 段的这 4 个字段。":
            "http-proxy-password is not edited here: writing it in plain text into a shared config file would undo the Keychain's protection. The original file is backed up before saving, and only those four `[global]` fields change.",
        "servers 文件中没有生效的认证 / TLS 相关字段。":
            "The servers file has no authentication or TLS settings in effect.",
        "[groups] 段（只读）": "[groups] section (read-only)",
        "打开 ~/.subversion 文件夹": "Open the ~/.subversion folder",
        "认证与 SASL": "Authentication and SASL",
        "认证 / TLS 字段与 [groups] 段只读展示，不做修改；http-proxy-password 等密码值一律脱敏，且不会被写入设置存储或日志。svnserve 的 SASL 与 svn+ssh 认证由系统 SASL 库、SSH 配置与 SSH_ASKPASS 管理，不通过这个配置文件控制；本应用的 svn 子进程是非交互的（--non-interactive），无法弹出终端密码提示，也不提供 iCloud 钥匙串同步。":
            "The authentication, TLS and `[groups]` entries are shown read-only and never modified; password values such as http-proxy-password are always redacted and never reach settings storage or the log. svnserve's SASL and svn+ssh authentication are governed by the system SASL library, the SSH configuration and SSH_ASKPASS, not by this file. This app's svn child process is non-interactive (`--non-interactive`), so it cannot pop a terminal password prompt, and it does not sync through iCloud Keychain.",
        "未配置（注释或未设置）": "Not configured (commented out or unset)",
        " · 用户 %@": " · user %@",
        " · 排除 %@": " · exceptions %@",
        "代理端口无效：应为 1–65535 的整数":
            "Invalid proxy port: expected an integer from 1 to 65535",
        "已备份原文件：%@": "Previous file backed up to %@",
        "已新建 servers 文件（原文件不存在，无需备份）":
            "Created a new servers file (there was nothing to back up)",
        "颁发机构未知（unknown-ca）": "Unknown authority (unknown-ca)",
        "域名不匹配（cn-mismatch）": "Host name mismatch (cn-mismatch)",
        "证书已过期（expired）": "Certificate expired (expired)",
        "证书尚未生效（not-yet-valid）": "Certificate not yet valid (not-yet-valid)",
        "其它校验失败（other）": "Other verification failure (other)",

        // MARK: - About pane

        "版本 %@": "Version %@",
        "工作副本格式": "Working copy format",
        "1.10 – 1.x（不自动升级未知格式）": "1.10 – 1.x (unknown formats are not upgraded)",
        "关闭（需要任意路径访问与子进程）": "Off (needs arbitrary path access and child processes)",
        "显示日志文件夹": "Show Log Folder",

        // MARK: - Extensions sheet

        "恢复默认模板": "Restore the default template",
        "工单号链接": "Ticket number links",
        "提交说明与历史消息里的 #123、PROJ-123、issue 123 会变成可点击链接。占位符：{id} 规范化编号、{number} 纯数字、{key} 项目前缀。":
            "#123, PROJ-123 and issue 123 in commit messages and history become clickable links. Placeholders: {id} for the normalised identifier, {number} for the bare number, {key} for the project prefix.",
        "任务完成或失败时发送通知": "Notify when a task finishes or fails",
        "现在请求通知授权": "Request Notification Permission",
        "已请求授权；若系统未弹出对话框，说明当前构建未签名或已授权过。":
            "Permission requested. If macOS showed no dialog, this build is unsigned or permission was already granted.",
        "操作通知": "Task notifications",
        "使用系统本地通知。未签名、未授权或开关关闭时会自动跳过，不会中断任何操作。":
            "Uses macOS notifications. Skipped silently when the build is unsigned, permission is missing, or the switch is off — no operation is ever interrupted.",
        "可执行文件路径": "Executable path",
        "外部合并工具": "External merge tool",
        "冲突解决入口提供「用外部工具解决」。占位符 {base}、{mine}、{theirs}、{merged}、{file} 会替换为文件路径；命令按参数数组执行，不会拼接 shell 字符串。工具需在 {merged} 写出结果并以 0 退出。":
            "The conflict resolver offers “Resolve with External Tool”. The placeholders {base}, {mine}, {theirs}, {merged} and {file} expand to file paths; the command runs from an argument array and never builds a shell string. The tool must write its result to {merged} and exit 0.",
        "完成": "Done",
        "选择用于三方合并的程序": "Choose the program used for three-way merges"
    ]
}
