import Foundation

/// English for the Core layer: discovery, errors, model-level labels and the
/// status text the services produce before the UI ever sees it.
///
/// Entries written as `%d` are plural-aware and must be read through
/// `Localization.n`; `%@` entries are read through `f`. The distinction is not
/// cosmetic — `f` on a two-form plural string would print the `|` separator.
enum StringsCore {
    static let table: [String: String] = [
        // MARK: - Discovery

        "手动指定": "Set manually",
        "应用内置": "Bundled with OpenSVN",
        "PATH 探测": "Found on PATH",
        "常见安装位置": "Standard install location",
        "指定的 svn 无法运行：%@": "The selected svn could not be launched: %@",
        "未找到可用的 svn 可执行文件": "No usable svn executable was found",
        "未检查任何候选路径": "no candidate path was checked",
        "已检查：\n": "Checked:\n",
        "svn 探测失败：%@": "Probing for svn failed: %@",
        "无法识别 svn 版本：%@": "Could not read the svn version: %@",
        "svn %@ 不在支持区间（>= %@, < %@）": "svn %@ is outside the supported range (>= %@, < %@)",

        // MARK: - SVNError

        "工作副本被锁定。请先执行 Cleanup 清理内部锁。":
            "The working copy is locked. Run Cleanup to clear the internal lock first.",
        "该工作副本由更新版本的 Subversion 创建，OpenSVN 不会自动升级它。请使用兼容版本的客户端。":
            "This working copy was created by a newer Subversion. OpenSVN will not upgrade it; use a compatible client.",
        "工作副本目录或磁盘不可写。请检查文件权限、只读卷或磁盘空间；Cleanup 无法解决只读磁盘。":
            "The working copy or its disk is not writable. Check permissions, read-only volumes and free space; Cleanup cannot fix a read-only disk.",
        "仓库的数据格式不在当前 svn 的支持范围内。OpenSVN 不会自动升级仓库，请使用与该仓库匹配的 svn，或由仓库管理员升级。":
            "This svn does not support the repository's data format. OpenSVN will not upgrade a repository; use the svn that matches it, or ask the repository administrator to upgrade.",
        "所选目录不是 SVN 工作副本，或已被移动。":
            "The selected folder is not an SVN working copy, or it has moved.",
        "需要输入该仓库的用户名与密码。":
            "This repository needs a username and password.",
        "凭据已被服务器拒绝，请检查用户名、密码或访问权限。":
            "The server rejected the credentials. Check the username, password and access rights.",
        "无法连接服务器，请检查网络、代理或仓库地址。":
            "Cannot reach the server. Check the network, proxy settings and repository URL.",
        "本地副本已过期，请先 Update 再提交。":
            "The working copy is out of date. Update before committing.",
        "仍有未解决的冲突，解决后需标记 resolve 才能提交。":
            "Conflicts are still unresolved. Resolve them and mark them resolved before committing.",
        "无法在解决冲突前备份文件，操作已中止以免数据丢失。请检查磁盘空间与目录写权限。":
            "Files could not be backed up before resolving, so the operation stopped to avoid data loss. Check free space and write permissions.",
        "该路径已被他人锁定。请对方解除锁定，或在确认风险后使用「强制锁定」抢占。":
            "Someone else holds the lock on this path. Ask them to release it, or take it over with “Force lock” once you accept the risk.",
        "该路径当前没有锁。它可能已被他人释放或抢占，刷新锁定状态后再操作。":
            "This path is not locked. The lock may have been released or taken over; refresh the lock status before retrying.",
        "服务器 SSH 主机密钥未被信任，请核对指纹后再连接。":
            "The server's SSH host key is not trusted. Verify the fingerprint before connecting.",
        "操作超时，可重试或检查网络。":
            "The operation timed out. Retry, or check the network.",
        "操作已取消。工作副本可能处于中间状态，必要时执行 Cleanup。":
            "The operation was cancelled. The working copy may be left mid-operation; run Cleanup if needed.",
        "该操作会修改或丢弃本地数据，需要确认后才能执行。":
            "This operation changes or discards local data and needs confirmation.",
        "未找到可用的 svn 可执行文件，请在设置中指定路径或安装运行时。":
            "No usable svn executable was found. Set its path in Settings, or install the runtime.",
        "当前 svn 版本不在支持区间内，请升级 OpenSVN 或改用受支持的 svn。":
            "This svn version is outside the supported range. Update OpenSVN or use a supported svn.",
        "目标路径不存在或已被删除。":
            "The target path does not exist or has been deleted.",
        "请查看诊断日志，如可复现请附上日志提交 issue。":
            "See the diagnostic log; if it reproduces, attach the log to an issue.",
        "操作已取消": "Operation cancelled",
        "操作超时（%@ 秒）": "Operation timed out (%@ s)",

        // MARK: - Error classification

        "工作副本被锁定或上一次操作未完成":
            "The working copy is locked or a previous operation never finished",
        "目标不是 SVN 工作副本": "The target is not an SVN working copy",
        "工作副本格式不受支持": "The working copy format is not supported",
        "工作副本目录或磁盘不可写": "The working copy folder or disk is not writable",
        "仓库数据格式不受支持": "The repository format is not supported",
        "服务器要求认证": "The server requires authentication",
        "认证被服务器拒绝": "The server rejected the credentials",
        "SSH 主机密钥校验失败": "SSH host key verification failed",
        "无法连接仓库服务器": "Cannot reach the repository server",
        "工作副本已过期": "The working copy is out of date",
        "存在未解决的冲突": "Unresolved conflicts remain",
        "路径不存在": "The path does not exist",
        "无法在解决冲突前备份文件，操作已中止":
            "Files could not be backed up before resolving, so the operation stopped",
        "路径已被他人锁定": "Someone else holds the lock on this path",
        "路径没有锁": "The path is not locked",
        "操作超时": "The operation timed out",
        "需要确认后才能执行": "This needs confirmation",
        "命令参数无效": "Invalid command arguments",
        "无法解析 svn 输出": "Could not parse the svn output",
        "svn 版本不受支持": "The svn version is not supported",
        "找不到 svn 可执行文件": "The svn executable was not found",
        "svn 执行失败（退出码 %@）": "svn failed (exit code %@)",
        "未知错误": "Unknown error",

        // MARK: - Conflict resolution choices

        "保留当前内容，仅清除冲突标记":
            "Keep the current content, clear only the conflict markers",
        "用我的版本覆盖（丢弃服务器改动）":
            "Take my version (discard the server's changes)",
        "用服务器版本覆盖（丢弃我的改动）":
            "Take the server version (discard my changes)",
        "恢复基线版本（丢弃双方改动）":
            "Restore the base revision (discard both sides)",
        "保留磁盘上的当前内容（可能仍含冲突标记），仅清除冲突状态。":
            "Keep what is on disk (it may still contain conflict markers) and clear only the conflict state.",
        "丢弃服务器带来的修改，只保留本地版本。此操作不可撤销。":
            "Discard the incoming server changes and keep only the local file. This cannot be undone.",
        "丢弃全部本地修改，改用服务器版本。此操作不可撤销。":
            "Discard all local changes and use the server version. This cannot be undone.",
        "还原到冲突前的基线版本，本地与该次服务器修改都会被丢弃。":
            "Restore the base revision from before the conflict. Both the local and the incoming changes are discarded.",

        // MARK: - Properties

        "属性名不能为空": "The property name cannot be empty",
        "属性名不能以空白开头或结尾":
            "The property name cannot start or end with whitespace",
        "属性名只能包含字母、数字、冒号、点、下划线和短横线：%@":
            "A property name may contain only letters, digits, colons, dots, underscores and hyphens: %@",
        "「%@」是 Subversion 内部使用的属性，不能手动设置":
            "“%@” is an internal Subversion property and cannot be set by hand",
        "自定义属性必须带命名空间，例如 custom:%@":
            "A custom property needs a namespace, for example custom:%@",

        // MARK: - Merge and switch previews

        "合并来源 URL 不能为空": "The merge source URL cannot be empty",
        "挑拣合并至少需要一个修订号": "A cherry-pick merge needs at least one revision",
        "两 URL 合并的两个来源都不能为空": "A two-URL merge needs both sources",
        "将「%@」合并到「%@」": "Merge %@ into %@",
        "将「%@」与「%@」的差异合并到「%@」":
            "Merge the difference between %@ and %@ into %@",
        "这是本地合并：改动先进入工作副本，需要再执行一次提交才会进入仓库。":
            "This is a local merge: the changes land in the working copy and only reach the repository with a separate commit.",
        "工作副本里未提交的修改可能与合并结果冲突；合并不会自动解决冲突，冲突会保留为待解决状态。":
            "Uncommitted local changes may conflict with the merge result. A merge does not resolve conflicts; they stay marked as unresolved.",
        "本预览不扫描工作副本，合并前请先刷新状态查看本地改动。":
            "This preview does not scan the working copy. Refresh the status to review local changes before merging.",
        "已启用 --record-only：只更新 svn:mergeinfo 合并记录，不改动文件内容。":
            "--record-only is on: only the svn:mergeinfo record is updated, file contents are left alone.",
        "已指定 --accept %@：冲突处理会覆盖本地或服务器端内容，不可撤销。":
            "--accept %@ is set: conflict handling overwrites local or server content and cannot be undone.",
        "切换目标 URL 不能为空": "The switch target URL cannot be empty",
        "将「%@」切换到「%@」": "Switch %@ to %@",
        "切换会把工作副本整体指向同一仓库内的另一个 URL（分支）；仓库 UUID 由 svn 校验，切到别的仓库会失败。":
            "A switch points the whole working copy at another URL (branch) in the same repository. svn checks the repository UUID, so switching to a different repository fails.",
        "本地未提交的修改会被尽量保留，但与切换后内容冲突时会进入待解决状态，不会自动合并。":
            "Uncommitted local changes are kept where possible; where they clash with the new content they become unresolved rather than being merged.",
        "本预览不扫描工作副本，切换前请先刷新状态查看并妥善处理本地改动。":
            "This preview does not scan the working copy. Refresh the status and deal with local changes before switching.",
        "目标修订号：-r %@。": "Target revision: -r %@.",
        "已启用 --ignore-externals：外挂工作副本不会被更新。":
            "--ignore-externals is on: external working copies are not updated.",
        "已启用 --force：未纳入版本控制的同名文件可能被覆盖。":
            "--force is on: unversioned files with the same name may be overwritten.",

        // MARK: - Patch summary

        "剥离层数不能为负数": "The strip count cannot be negative",
        "读不到补丁文件：%@": "Cannot read the patch file: %@",
        "将影响 %d 个文件": "Would affect %d file|Would affect %d files",
        "已应用 %d 个文件": "Applied %d file|Applied %d files",
        "新增 %@": "added %@",
        "删除 %@": "deleted %@",
        "合并 %@": "merged %@",
        "冲突 %@": "conflicted %@",
        "跳过 %@": "skipped %@",

        // MARK: - Working-copy depth

        "完整（含所有子目录）": "Fully recursive",
        "仅直接子项": "Immediate children only",
        "仅文件": "Files only",
        "仅目录本身": "This folder only",
        "排除（从工作副本移除）": "Exclude (remove from the working copy)",
        "递归取出全部内容。已经排除的路径不会自动回来，需要单独设置。":
            "Fetch everything, recursively. A path that was excluded does not come back on its own; set it individually.",
        "取出这一层和直接子项；子目录保留为空壳，内部内容不下载。":
            "Fetch this level and its immediate children. Subfolders stay as empty shells with nothing inside.",
        "只取出这一层的文件，子目录整体不下载。":
            "Fetch only the files in this level. Subfolders are not fetched at all.",
        "只保留这个目录本身，子项从磁盘删除但仓库里仍然记得它们。":
            "Keep only this folder. Its children are deleted from disk but remain in the repository.",
        "把这个路径从工作副本里彻底移除，磁盘上的内容会被删除。":
            "Remove this path from the working copy entirely; its content is deleted from disk.",
        "磁盘上的文件会被删除，且仓库不再记得它们。目录里若有未纳入版本控制的文件，svn 会留下一个半成品并可能锁住工作副本，所以必须先清空。":
            "Files are deleted from disk and the repository forgets them. If the folder still holds unversioned files svn leaves the operation half-done and may lock the working copy, so it has to be emptied first.",
        "子项会从磁盘删除。它们仍在仓库里，改回更大的深度即可重新取回。":
            "Children are deleted from disk. They remain in the repository; raise the depth again to fetch them back.",

        // MARK: - History filter

        "作者": "Author",
        "路径": "Path",
        "日期": "Date",

        // MARK: - XML parsing

        "根元素不是 <status>": "The root element is not <status>",
        "根元素不是 <log>": "The root element is not <log>",
        "根元素不是 <lists>": "The root element is not <lists>",
        "<lists> 中没有 <list>": "No <list> inside <lists>",
        "根元素不是 <blame>": "The root element is not <blame>",
        "<blame> 中没有 <target>": "No <target> inside <blame>",
        "根元素不是 <info>": "The root element is not <info>",
        "<info> 中没有 <entry>": "No <entry> inside <info>",
        "根元素不是 <properties>": "The root element is not <properties>",
        "空的 %@ XML": "Empty %@ XML",
        "无法解析 svn %@ XML：%@": "Could not parse the svn %@ XML: %@",

        // MARK: - Process runner

        "找不到可执行的 svn：%@": "The svn executable cannot be found: %@",
        "工作目录不存在：%@": "The working directory does not exist: %@",
        "无法启动 svn：%@": "Could not launch svn: %@",
        "操作已取消：%@": "The operation was cancelled: %@",

        // MARK: - Conflict guard

        "无法创建冲突备份目录": "Could not create the conflict backup folder",
        "备份冲突文件失败：%@": "Backing up the conflict files failed: %@",
        "无法读取文件": "The file could not be read",
        "文件过大（%@ 字节），未扫描冲突标记":
            "File too large (%@ bytes); conflict markers were not scanned",
        "二进制文件": "Binary file",
        "非 UTF-8 文本": "Not UTF-8 text",

        // MARK: - Keychain

        "Keychain 操作失败（%@）：%@": "Keychain operation failed (%@): %@",
        "Keychain 中的凭据数据已损坏": "The credential data in the Keychain is corrupted",

        // MARK: - Demo workspace (UI labels only; the folder names and commit
        // messages it writes are fixture content and stay in one language so the
        // demo is reproducible)

        "准备演示目录": "Preparing the demo folder",
        "创建本地仓库": "Creating the local repository",
        "导入示例文件": "Importing the sample files",
        "检出工作副本": "Checking out the working copy",
        "提交服务器端的改动": "Committing the server-side changes",
        "制造冲突": "Creating conflicts",
        "校验冲突": "Verifying the conflicts",
        "「%@」已存在，且不是 OpenSVN 演示目录。为免覆盖你自己的文件，已停止。请换一个位置，或先把它移走。":
            "“%@” already exists and is not an OpenSVN demo folder. It was left untouched so your own files are not overwritten. Pick another location, or move that folder away first.",
        "此目录由 OpenSVN 生成，仅用于体验合并，可随时整体删除。\n":
            "This folder was generated by OpenSVN to demo a merge. It can be deleted at any time.\n",
        "无法读取演示工作副本的状态：%@":
            "Could not read the status of the demo working copy: %@",
        "演示工作副本只生成了 %@ 处冲突（预期至少 3 处）。请删除「%@」后重试。":
            "The demo working copy produced only %@ conflicts; at least 3 were expected. Delete “%@” and try again.",
        "%@失败：%@": "%@ failed: %@",
        "退出码 %@": "exit code %@",

        // MARK: - Operation journal (recovery banner)

        "检出": "Check out",
        "更新": "Update",
        "提交": "Commit",
        "添加": "Add",
        "删除": "Delete",
        "还原": "Revert",
        "解决冲突": "Resolve conflicts",
        "清理": "Clean up",
        "修改属性": "Edit properties",
        "锁定": "Lock",
        "解锁": "Unlock",
        "应用补丁": "Apply patch",
        "提交可能已经到达服务器，也可能没有。先刷新状态确认，不要直接重复提交。":
            "The commit may or may not have reached the server. Refresh the status to find out — do not simply commit again.",
        "检出可能只完成了一部分。确认目录内容后再决定是继续还是删掉重来。":
            "The checkout may be only partly done. Check what is in the folder before deciding to continue or start over.",
        "工作副本可能停在中间状态。运行「清理」后再刷新状态。":
            "The working copy may be left mid-operation. Run “Clean up”, then refresh the status.",
        "工作副本可能停在中间状态，未匹配的部分会留下 .svnpatch.rej。运行「清理」后查看状态；确认不要这些改动用「还原」。":
            "The working copy may be left mid-operation, with `.svnpatch.rej` files next to the hunks that did not apply. Run “Clean up”, inspect the status, and use “Revert” if you do not want the changes.",
        "锁可能已在服务器上生效。刷新锁定状态确认，再决定是否重试。":
            "The lock may already be in place on the server. Refresh the lock status before retrying.",
        "锁可能已释放。刷新锁定状态确认，不要直接重复解锁。":
            "The lock may already be released. Refresh the lock status rather than unlocking again.",
        "上次清理没有完成。重新运行「清理」即可。":
            "The last cleanup did not finish. Run “Clean up” again.",

        // MARK: - Log levels

        "不记录": "Off",
        "仅错误": "Errors only",
        "错误与警告": "Errors and warnings",
        "常规": "Normal",
        "调试": "Debug",
        "不写日志文件。出问题时没有可查记录。":
            "No log file is written. If something goes wrong there is nothing to look at.",
        "只记录失败的操作。": "Records failed operations only.",
        "记录失败与可疑情况，适合日常使用。":
            "Records failures and anything suspicious. A sensible everyday setting.",
        "记录每次 SVN 命令的结果，不含完整输出。":
            "Records the result of every SVN command, without the full output.",
        "记录完整的命令与输出（已脱敏），仅用于排查问题。":
            "Records full commands and output, with secrets redacted. For troubleshooting only.",

        // MARK: - Update check

        "有可用更新：%@": "An update is available: %@",
        "已是最新版本": "Up to date",
        "还没有发布版本": "No releases yet",
        "当前 %@，最新 %@。": "Current %@, latest %@.",
        "这是一个预发布版本。": "This is a pre-release.",
        "这个版本不会自动安装：下载后手动替换应用即可。":
            "This release cannot install itself: download it and replace the app by hand.",
        "可以在应用内下载、校验并安装这个版本；安装会在你确认后、退出应用时替换旧版本。":
            "This release can be downloaded, verified and installed inside the app; it replaces the old copy when you quit, after you confirm.",
        "当前 %@，服务器上的最新正式版本是 %@，没有比它更新的版本。":
            "Current %@; the newest stable release on the server is %@, so there is nothing newer.",
        "当前 %@，服务器上没有更新的版本。":
            "Current %@; the server has nothing newer.",
        "当前 %@。这个仓库还没有发布过任何版本，所以没有可比较的对象。":
            "Current %@. This repository has never published a release, so there is nothing to compare against.",
        "无法连接到发布服务器：%@": "Could not reach the release server: %@",
        "发布服务器拒绝了这次检查（HTTP %@），通常是请求太频繁，稍后再试。":
            "The release server refused the check (HTTP %@). That usually means too many requests; try again later.",
        "发布服务器返回了 HTTP %@。": "The release server returned HTTP %@.",
        "发布服务器的响应无法解析。": "The release server's response could not be parsed.",

        // MARK: - Connection settings (svn servers file)

        "代理端口无效：%@（应为 1–65535）":
            "Invalid proxy port: %@ (expected 1–65535)",
        "配置值包含不允许的字符：%@":
            "The value contains characters that are not allowed: %@",
        "无法读取 servers 配置文件": "The servers config file could not be read",
        "无法写入 servers 配置文件": "The servers config file could not be written",

        // MARK: - Task center

        "正在取消…": "Cancelling…",

        // MARK: - Vocabulary shared by several services

        "仓库": "Repository",
        "，": ", ",
        "、": ", "
    ]
}
