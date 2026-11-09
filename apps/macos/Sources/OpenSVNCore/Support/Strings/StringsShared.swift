import Foundation

/// English for the shell around the work: the main window, the sidebar, the
/// shared sheets (credentials, checkout, demo, update, task centre) and the
/// status badges.
///
/// The status badges are the tightest constraint in the app: they sit in a
/// narrow column, so their English stays to one or two words and never repeats
/// the column header ("Status: Conflicted", not "Status: Conflict status").
enum StringsShared {
    static let table: [String: String] = [
        // MARK: - Main window

        "添加工作副本": "Add Working Copy",
        "添加一个已存在的工作副本": "Add a working copy that is already on this Mac",
        "从仓库检出新的工作副本": "Check out a new working copy from a repository",
        "任务": "Tasks",
        "无法使用 SVN": "SVN Is Unavailable",
        "打开设置…": "Open Settings…",
        "好": "OK",
        "快速查看": "Quick Look",
        "在终端打开": "Open in Terminal",
        "在 Finder 中显示": "Reveal in Finder",
        "导出所选…": "Export Selected…",
        "新建本地仓库…": "New Local Repository…",
        "用 svnadmin 在这台 Mac 上创建仓库，不需要服务器":
            "Create a repository on this Mac with svnadmin — no server needed",
        "用外部工具解决冲突…": "Resolve Conflict with External Tool…",
        "新建窗口": "New Window",
        "扩展设置…": "Extensions…",
        "快捷操作": "Quick Actions",
        "快速查看、在终端打开、导出、外部合并、扩展设置与新建窗口":
            "Quick Look, open in Terminal, export, external merge, extensions and a new window",
        "导出到此处": "Export Here",
        "选择目标目录：svn export 不会覆盖已有文件":
            "Choose a destination folder: svn export never overwrites existing files",
        "选择左侧的工作副本，或添加一个新的。":
            "Choose a working copy on the left, or add one.",
        "添加工作副本…": "Add Working Copy…",
        "检出仓库…": "Check Out Repository…",
        "在这台 Mac 上新建一个本地仓库（不需要服务器）":
            "Create a local repository on this Mac (no server needed)",
        "想先试试三方合并？用一份带冲突的演示数据":
            "Want to try a three-way merge? Use a demo repository with a conflict",
        "使用 svn %@ · %@": "Using svn %@ · %@",

        // MARK: - Sidebar

        "工作副本": "Working copies",
        "检查连接": "Check Connection",
        "移除": "Remove",
        "复制地址": "Copy URL",
        "没有工作副本": "No working copies",
        "添加一个已存在的工作副本，或从仓库检出。":
            "Add a working copy that is already here, or check one out.",
        "添加…": "Add…",
        "检出…": "Check Out…",
        "只看仓库…": "Browse a Repository…",
        "%d 个冲突": "%d conflict|%d conflicts",

        // MARK: - Status badges

        "冲突": "Conflicted",
        "已修改": "Modified",
        "已新增": "Added",
        "已删除": "Deleted",
        "未纳入版本控制": "Unversioned",
        "外部工作副本": "External",
        "已忽略": "Ignored",
        "正常": "Normal",
        "其他": "Other",
        "文本冲突": "Text conflict",
        "属性冲突": "Property conflict",
        "树冲突": "Tree conflict",

        // MARK: - Commit file history sheet

        "文件历史": "File History",
        "正在读取历史…": "Reading history…",
        "加载更早的提交": "Load Earlier Commits",
        "变更路径（%@）": "Changed paths (%@)",
        "选择一个修订版本": "Select a revision",

        // MARK: - Credentials and checkout

        "需要认证": "Authentication Required",
        "密码": "Password",
        "凭据只保存在 macOS 钥匙串。密码通过标准输入传给 svn，不会出现在命令行参数中。":
            "Credentials are kept in the macOS Keychain only. The password is passed to svn on standard input and never appears in the command line.",
        "登录": "Sign In",
        "检出仓库": "Check Out Repository",
        "仓库 URL": "Repository URL",
        "目标目录": "Destination",
        "检出深度": "Checkout depth",
        "修订版本（可选）": "Revision (optional)",
        "留空表示 HEAD": "Leave empty for HEAD",
        "不保存原始副本，按需从仓库获取（--store-pristine=no）":
            "Do not keep pristine copies; fetch them from the repository on demand (--store-pristine=no)",
        "检出在后台执行，可在任务中心查看进度或取消。":
            "The checkout runs in the background; follow its progress or cancel it in the task centre.",
        "检出中…": "Checking out…",
        "按需获取原始副本需要 svn 1.15 或更高版本；当前 %@，因此该选项不可用。":
            "Fetching pristine copies on demand needs svn 1.15 or later; this Mac has %@, so the option is unavailable.",
        "关闭后工作副本不再本地保存原始副本，磁盘占用更小，但格式会升级到 32：svn 1.14 及更旧客户端将无法打开这个工作副本，且无法降级。":
            "Without pristine copies the working copy takes less space, but its format is upgraded to 32: svn 1.14 and older can no longer open it, and there is no way back.",
        "选择检出目标目录（可为空目录）": "Choose the destination folder (it may be empty)",

        // MARK: - Demo workspace sheet

        "亲手试一次三方合并": "Try a Three-Way Merge Yourself",
        "在本机生成一个带冲突的小仓库，不需要联网，也不会动你的其他文件。":
            "Builds a small repository with a conflict on this Mac. No network, and none of your other files are touched.",
        "三方合并要准备两份工作副本和一次真实冲突 —— 为了试一个功能做这些不值得。点下面的按钮，这些都由 OpenSVN 代劳。":
            "Setting up a three-way merge means two working copies and a real conflict — not worth it just to try a feature. Press the button and OpenSVN does it for you.",
        "生成后你会看到": "What you will see",
        "3 处自动合并，1 处需要你决定": "3 automatic merges, 1 decision for you",
        "2 处自动合并，1 处需要你决定": "2 automatic merges, 1 decision for you",
        "中文文件名，同样可以合并": "A Chinese file name merges just the same",
        "属性冲突 —— 三方合并处理不了，需要整体选一边":
            "A property conflict — three-way merging cannot handle it, one side has to win",
        "只有服务器改过，更新时已经自动合并":
            "Only the server changed these; the update already merged them",
        "正在生成…": "Generating…",
        "重新生成": "Generate Again",
        "打开演示": "Open the Demo",
        "生成并打开": "Generate and Open",

        // MARK: - Filter field

        "清除筛选内容": "Clear the filter",
        "筛选": "Filter",

        // MARK: - New local repository sheet

        "新建本地仓库": "New Local Repository",
        "在这台 Mac 上创建仓库，不需要服务器。":
            "Create a repository on this Mac — no server needed.",
        "仓库目录": "Repository folder",
        "这会执行 `svnadmin create`。目标目录必须不存在或为空——已存在非空目录会被拒绝，不会覆盖任何东西。勾选下面的选项时会同时检出这个仓库，得到一个可提交的工作副本（与其同级的 `<名称>-wc` 目录）。":
            "This runs `svnadmin create`. The destination must not exist, or must be empty — an existing non-empty folder is refused and nothing is overwritten. Ticking the option below also checks the repository out into a committable working copy (a `<name>-wc` folder beside it).",
        "已创建并检出": "Created and checked out",
        "创建中…": "Creating…",
        "创建并检出": "Create and Check Out",
        "在此新建": "Create Here",
        "选择新仓库的父目录，仓库会建在里面":
            "Choose the parent folder; the repository is created inside it",

        // MARK: - Misc shared views

        "无法创建快速查看预览": "Could not create the Quick Look preview",
        "操作记录文件无法读取": "The operation journal cannot be read",
        "已保留为 %@，无法判断上次是否有操作被中断。":
            "It was kept as %@, so there is no way to tell whether an operation was interrupted.",
        "知道了": "Got It",
        "上次有 %d 项操作没有正常结束": "%d operation did not finish last time|%d operations did not finish last time",
        "全部忽略": "Ignore All",
        "还有 %d 项未显示": "%d more not shown",
        "运行 svn cleanup，把工作副本从中间状态恢复":
            "Run `svn cleanup` to bring the working copy back from a half-finished state",
        "显示": "Show",
        "忽略": "Ignore",
        "任务中心": "Task Centre",
        "清除已完成": "Clear Finished",
        "没有任务": "No tasks",
        "第 %d 次尝试": "Attempt %d",
        "%.1f 秒": "%.1f s",
        "重新执行同一项请求。不会跳过任何确认，也不改变第一次失败时的参数。":
            "Runs the same request again. No confirmation is skipped, and the arguments from the first attempt are kept.",
        "识别到工单": "Ticket detected",

        // MARK: - Update check sheet

        "安装更新并重新启动？": "Install the update and relaunch?",
        "重新启动并安装": "Relaunch and Install",
        "应用会退出，更新包会被复制到 %@ 并重新打开。签名校验已通过，替换失败时会自动恢复旧版本。":
            "The app quits, the update is copied to %@ and reopened. Verification already passed; if replacing fails, the old version is restored.",
        "检查更新只读取项目 Releases 的公开信息，不发送任何本机数据。失败不影响工作副本的任何操作。":
            "The update check reads the project's public release information only and sends nothing about this Mac. A failure never affects working-copy operations.",
        "还没有结果。": "No result yet.",
        "安装包会先下载到「应用支持」目录，校验 SHA-256 与发布签名（项目密钥或 Developer ID）之后才允许替换当前应用。":
            "The installer is downloaded into Application Support first, and only replaces the running app after its SHA-256 and release signature (project key or Developer ID) check out.",
        "正在校验发布清单与更新包…": "Verifying the release manifest and the update…",
        "%@ 已下载并通过签名校验。": "%@ was downloaded and passed signature verification.",
        "正在安装并重新启动…": "Installing and relaunching…",
        "已下载 %@": "Downloaded %@",
        "已下载 %@ / %@": "Downloaded %@ of %@",
        "启动时检查": "Check at launch",
        "只在启动时询问一次，每天最多一次":
            "Asked once at launch, at most once a day",
        "取消下载": "Cancel Download",
        "下载并安装": "Download and Install",
        "下载": "Download",
        "打开发布页": "Open the Release Page",
        "检查更新失败": "The update check failed",
        "检查更新": "Check for Updates",
        "正在查询发布信息…": "Reading the release information…",
        "当前版本 %@": "Current version %@",
        "未知版本": "an unknown version"
    ]
}
