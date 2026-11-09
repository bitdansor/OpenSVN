import Foundation

/// English for the app layer: `AppState`, the two view models, the local models
/// and the support helpers that build text (task notifications, drop import).
///
/// Counts that appear inside a sentence are `%d` entries with two English forms,
/// so the noun and the verb agree with the number. A single neutral form would
/// read as machine translation at exactly the moment the user is reading a
/// summary of what just happened to their files.
enum StringsApp {
    static let table: [String: String] = [
        // MARK: - AppState: lifecycle and startup

        "所选目录不是 SVN 工作副本：%@": "The selected folder is not an SVN working copy: %@",
        "只看仓库（不检出）": "Browse only (no checkout)",
        "只看仓库（不检出）…": "Browse Only (No Checkout)…",
        "非文本": "non-text",
        "输入仓库地址。浏览、建目录、打 tag 都不需要把文件拉到本地。":
            "Enter the repository URL. Browsing, creating folders and tagging all work without fetching anything to this Mac.",
        "仓库地址需要包含协议（例如 https:// 或 svn://）：%@":
            "The repository URL needs a scheme (for example https:// or svn://): %@",
        "选择 SVN 工作副本目录（包含 .svn 的目录）":
            "Choose an SVN working copy folder (the one containing .svn)",
        "svn 还没有就绪，无法生成演示。":
            "svn is not ready yet, so the demo cannot be generated.",
        "找不到 svnadmin（应当与 svn 在同一目录）。请安装完整版 Subversion，":
            "svnadmin was not found (it should sit next to svn). Install the full Subversion package,",
        "或在终端运行 scripts/create-conflict-demo.sh。":
            "or run scripts/create-conflict-demo.sh in Terminal.",
        "请输入用户名": "Enter a username",
        "SVN 服务尚未就绪，暂时无法清理。":
            "The SVN service is not ready, so cleanup is unavailable right now.",
        "目录已不存在：%@": "The folder no longer exists: %@",
        "清理失败：%@": "Cleanup failed: %@",
        "SVN 服务尚未就绪": "The SVN service is not ready",
        "检出 %@": "Check out %@",

        // MARK: - AppState: updates

        "这个版本没有提供可校验的安装包，只能下载后手动安装。":
            "This release offers no verifiable installer, so it can only be downloaded and installed by hand.",
        "这个发布用项目密钥签了摘要，但当前构建没有内置对应的公钥，无法校验，只能手动下载。":
            "This release signs its digest with the project key, but this build has no matching public key compiled in, so it cannot be verified and must be downloaded by hand.",
        "发布方既没有提供签名清单，也没有提供 SHA-256 摘要，无法校验，只能手动下载。":
            "The publisher supplied neither a signed manifest nor a SHA-256 digest, so the download cannot be verified and has to be done by hand.",
        "这个发布没有附带签名清单，而当前构建不是 Developer ID 签名，无法确认发布者，因此不会自动安装。":
            "This release carries no signed manifest, and this build is not Developer ID signed, so the publisher cannot be identified. It will not be installed automatically.",
        "下载失败。": "The download failed.",
        "发布清单校验失败。": "The release manifest failed verification.",
        "更新包校验失败。": "The update failed verification.",
        "无法启动安装。": "The installation could not be started.",

        // MARK: - App commands

        "刷新状态": "Refresh Status",
        "清理工作副本": "Clean Up Working Copy",
        "任务中心…": "Task Centre…",
        "取消全部任务": "Cancel All Tasks",
        "试一次三方合并…": "Try a Three-Way Merge…",
        "任务完成": "Task finished",
        "任务失败": "Task failed",

        // MARK: - Repository browser

        "新建目录": "Create Folder",
        "创建 tag": "Create Tag",
        "复制到": "Copy To",
        "移动到": "Move To",
        "删除仓库路径": "Delete Repository Path",
        "创建": "Create",
        "复制": "Copy",
        "移动": "Move",
        "%@，提交为 r%@": "%@, committed as r%@",
        "已导出到 %@": "Exported to %@",
        "目标路径不能为空": "The target path cannot be empty",

        // MARK: - RepositorySession: connectivity

        "尚未检查服务器连通性": "Server connectivity has not been checked yet",
        "服务器可达（%@）": "Server reachable (%@)",
        "服务器需要认证，尚未保存可用的凭据":
            "The server needs authentication and no usable credentials are saved",
        "服务器不可达：%@": "Server unreachable: %@",

        // MARK: - RepositorySession: day-to-day operations

        "添加到版本控制": "Add to version control",
        "删除 %d 项": "Delete %d item|Delete %d items",
        "还原 %d 项": "Revert %d item|Revert %d items",
        "无法确定仓库地址，历史搜索需要先读取工作副本信息":
            "The repository URL cannot be determined; history search needs the working copy's information first",
        "（无提交说明）": "(no commit message)",
        "变更 %d 个路径：": "Changed %d path:|Changed %d paths:",
        "- … 其余 %d 个": "- … %d more",
        "请先勾选要提交的文件": "Select the files to commit first",
        "提交 %d 个文件": "Commit %d file|Commit %d files",
        "解决冲突：%@": "Resolve conflict: %@",
        "确认解决": "Resolve",
        "该路径当前没有冲突副本，无法进行三方合并":
            "This path has no conflict copy, so a three-way merge is not possible",
        "冲突副本不完整（可能是树冲突或已被清理），请改用「解决冲突」菜单":
            "The conflict copy is incomplete — a tree conflict, or it was cleaned up. Use the “Resolve conflicts” menu instead",
        "只有文本冲突支持三方合并；这是%@冲突":
            "Only text conflicts support a three-way merge; this one is a %@ conflict",
        "写入合并结果": "Write merge result",
        "\n\n合并前的内容已备份到：\n":
            "\n\nThe content from before the merge was backed up to:\n",
        "将一次处理 %d 个文件：": "This will handle %d file:|This will handle %d files:",
        "… 其余 %d 个": "… %d more",
        "解决前会把冲突相关文件备份到应用支持目录，出问题可以从那里取回。":
            "Before resolving, the files involved are backed up to the Application Support folder so you can recover them if something goes wrong.",
        "已备份 %@ 个冲突文件到：\n%@":
            "Backed up %@ conflict file(s) to:\n%@",
        "没有需要备份的冲突副本（可能已被他人解决或文件已删除）。":
            "There was nothing to back up — the conflict may have been resolved by someone else, or the file deleted.",
        "%d 个文件无法扫描（二进制或超过 8 MB）。":
            "%d file could not be scanned (binary, or larger than 8 MB).|%d files could not be scanned (binary, or larger than 8 MB).",
        "已解决 %d 个冲突": "Resolved %d conflict|Resolved %d conflicts",
        "以下文件仍含冲突标记（`<<<<<<<` / `>>>>>>>`），直接提交会把标记写进仓库：":
            "These files still contain conflict markers (`<<<<<<<` / `>>>>>>>`). Committing now would write them into the repository:",
        "· %@（第 %@%@ 行）": "· %@ (line %@%@)",
        "请手工编辑这些文件，或在「变更」页改用其它解决方式。":
            "Edit them by hand, or pick a different resolution from the Changes page.",
        "已标记为已解决，但仍有 %d 个文件含冲突标记":
            "Marked resolved, but %d file still contains conflict markers|Marked resolved, but %d files still contain conflict markers",
        "忽略「%@」": "Ignore “%@”",
        "忽略 %d 项": "Ignore %d item|Ignore %d items",
        "忽略 %@": "Ignore %@",

        // MARK: - RepositorySession: locks

        "锁定「%@」": "Lock “%@”",
        "锁定 %d 项": "Lock %d item|Lock %d items",
        "（强制）": " (forced)",
        "强制锁定会抢占以下路径上他人持有的锁：\n":
            "Force locking takes locks other people hold on these paths:\n",
        "\n\n持有者将无法提交，直到他发现锁已易主。":
            "\n\nThe holders cannot commit until they notice the lock has changed hands.",
        "强制锁定": "Force Lock",
        "该路径已由 %@ 锁定": "This path is already locked by %@",
        "\n… 其余 %d 项": "\n… %d more",
        "将解除 %d 个路径的锁：": "Unlock %d path:|Unlock %d paths:",
        "其中 %d 个锁由他人持有。解除需要强制，持有者将失去保护。":
            "%d of the locks belong to someone else. Unlocking them needs force, and the holders lose their protection.|%d of the locks belong to someone else. Unlocking them needs force, and the holders lose their protection.",
        "如果只是在本地不想被锁影响，也可以不解除，直接继续编辑。":
            "If you only want to work locally, you can leave the locks alone and keep editing.",
        "强制解除 %d 个锁": "Force Unlock %d Lock|Force Unlock %d Locks",
        "解除 %d 个锁": "Unlock %d Lock|Unlock %d Locks",
        "强制解除": "Force Unlock",
        "解除锁定": "Unlock",
        "强制解除锁": "Force Unlock",

        // MARK: - RepositorySession: import, export, merge, switch, depth

        "新的仓库地址需要包含协议": "The new repository URL needs a scheme",
        "无法确定仓库地址（file:// 之外的工作副本需要先读取信息）":
            "The repository URL cannot be determined (a working copy other than file:// has to be read first)",
        "拖入的文件已不存在，未导入任何内容":
            "The dropped files no longer exist, so nothing was imported",
        "导入到工作副本": "Import into the working copy",
        "将把 %@%@ 复制到「%@」并加入版本控制（svn add），不会立即提交。":
            "This copies %@%@ into “%@” and adds it to version control (`svn add`). Nothing is committed yet.",
        "导入": "Import",
        "工作副本里已存在同名项目：%@":
            "The working copy already contains an item with that name: %@",
        "导出 %d 项": "Export %d item|Export %d items",
        "合并来源：%@": "Merge source: %@",
        "这是一次 --record-only 合并：只更新 svn:mergeinfo 记录，没有改动任何文件。":
            "This was a --record-only merge: only svn:mergeinfo changed, no file was touched.",
        "没有文件发生变化：这段修订可能已经合并过了（见「信息」页的合并记录）。":
            "Nothing changed: these revisions may already have been merged (see the merge records on the Info page).",
        "改动 %d 个路径。": "Changed %d path.|Changed %d paths.",
        "其中 %d 个路径冲突，未自动解决——请到「变更」页逐个处理后再提交。":
            "%d path is in conflict and was left unresolved — work through them on the Changes page before committing.|%d paths are in conflict and were left unresolved — work through them on the Changes page before committing.",
        "改动还在工作副本里：确认无误后到「提交」页提交。":
            "The changes are in the working copy only: review them on the Commit page when you are ready.",
        "%d 个路径被跳过（Skipped），通常是本地已存在未纳入版本控制的同名文件。":
            "%d path was skipped — usually an unversioned file of the same name already exists.|%d paths were skipped — usually an unversioned file of the same name already exists.",
        "合并完成": "Merge complete",
        "切换到 %@": "Switch to %@",
        "工作副本现在指向：%@": "The working copy now points at: %@",
        "内容随之更新了 %d 个路径。":
            "Its content changed in %d path.|Its content changed in %d paths.",
        "其中 %d 个路径冲突——本地未提交的修改与切换后的内容撞在了一起，请到「变更」页处理。":
            "%d path is in conflict — uncommitted local changes clash with the new content. Handle it on the Changes page.|%d paths are in conflict — uncommitted local changes clash with the new content. Handle them on the Changes page.",
        "本地未提交的修改已被保留。":
            "Uncommitted local changes were kept.",
        "切换完成": "Switch complete",
        "改深度：%@": "Change depth: %@",

        // MARK: - RepositorySession: external merge

        "尚未配置外部合并工具，请在「扩展设置」里指定可执行文件":
            "No external merge tool is configured. Choose an executable in “Extensions”.",
        "「%@」没有完整的三方冲突副本，无法用外部工具合并":
            "“%@” has no complete set of three-way conflict copies, so an external tool cannot merge it",
        "外部合并工具以退出码 %@ 结束，未写入任何改动":
            "The external merge tool exited with code %@ and wrote nothing",
        "外部合并工具没有在 {merged} 位置写出合并结果":
            "The external merge tool did not write a result to {merged}",
        "写入外部合并结果": "Write external merge result",
        "已用外部工具解决冲突": "Conflict resolved with an external tool",
        "「%@」的合并结果已写回并标记为已解决。":
            "The merge result for “%@” was written back and marked resolved."
    ]
}
