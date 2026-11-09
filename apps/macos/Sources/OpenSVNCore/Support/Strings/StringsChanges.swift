import Foundation

/// English for the Changes page, the conflict guide and the Commit page.
///
/// Two conventions here:
///
/// - Counts that carry a noun use `%d` so the noun can inflect. Where a sentence
///   would need verb agreement too, the English drops the noun entirely
///   ("%@ in conflict") rather than printing "1 files".
/// - The page's own vocabulary is fixed: a "conflict copy" is what svn leaves
///   beside the file, "resolve" is the act of deciding, and "commit" is the only
///   word used for sending changes to the server.
enum StringsChanges {
    static let table: [String: String] = [
        // MARK: - Changes: empty states and filtering

        "正在读取工作副本…": "Reading the working copy…",
        "工作副本干净": "The working copy is clean",
        "没有本地修改。": "No local changes.",
        "没有匹配的文件": "No matching files",
        "「%@」没有匹配任何变更。": "Nothing in “%@” matches.",
        "清除过滤": "Clear filter",
        "过滤文件（空格分隔多个关键词）": "Filter files (space-separated keywords)",
        "显示 %@ / %@ 项": "Showing %@ of %@",

        // MARK: - Changes: badges and row menu

        "外部": "External",
        "该路径位于 svn:externals 挂载的工作副本内，要提交得去那个工作副本":
            "This path lives in a working copy mounted by svn:externals; commit it from that one",
        "三方合并": "Three-way merge",
        "并排比较我的改动、基线和服务器改动，逐块决定保留哪一边":
            "Compare my changes, the base and the server's side by side, and decide block by block",
        "已锁定": "Locked",
        "需清理": "Needs cleanup",
        "属性": "Properties",
        "查看差异": "Show Diff",
        "忽略此文件": "Ignore This File",
        "忽略所有 .%@ 文件": "Ignore All .%@ Files",
        "查看此文件的历史": "Show This File's History",
        "注解（谁写的）…": "Blame (who wrote it)…",
        "属性…": "Properties…",
        "三方合并…": "Three-Way Merge…",
        "并排比较我的改动、基线和服务器改动，逐块选择":
            "Compare my changes, the base and the server side by side, and pick block by block",
        "还原本地修改…": "Revert Local Changes…",
        "删除…": "Delete…",
        "解除锁定…": "Unlock…",
        "锁定…": "Lock…",
        "强制抢占锁定…": "Force Take Lock…",

        // MARK: - Changes: lock badge

        "本工作副本持有该锁": "This working copy holds the lock",
        "锁由 %@ 持有": "Locked by %@",
        "说明：%@": "Comment: %@",
        "锁定于 %@": "Locked on %@",
        "解除需要强制，且会让对方无法提交。":
            "Unlocking needs force, and leaves the other person unable to commit.",
        "去提交": "Go to Commit",

        // MARK: - Changes: toolbar

        "忽略所选文件": "Ignore Selected Files",
        "把所选文件加入各自目录的 svn:ignore":
            "Add the selected files to svn:ignore in their own folders",
        "正在查询锁定…": "Checking locks…",
        "刷新锁定状态": "Refresh Lock Status",
        "向服务器查询这些文件上的锁（包括他人持有的）":
            "Ask the server about locks on these files, including other people's",
        "还原…": "Revert…",
        "解决全部冲突（%@）": "Resolve All Conflicts (%@)",
        "操作": "Actions",
        "显示全部": "Show All",
        "将所选加入": "Add Selected To",
        "新建变更集…": "New Changeset…",
        "移出变更集": "Remove from Changeset",
        "变更集": "Changeset",
        "变更集只存在于本地，用来把改动分组；提交时按勾选，不按变更集":
            "Changesets are local grouping labels only. Commits follow the tick boxes, not the changeset.",

        // MARK: - Changes: new changeset sheet

        "新建变更集": "New Changeset",
        "变更集是本地标签，不会提交到服务器。":
            "A changeset is a local label; it is never sent to the server.",
        "例如 ui-review": "for example ui-review",
        "未选择": "Nothing selected",
        "已选择 %d 项": "%d item selected|%d items selected",

        // MARK: - Conflict guide banner

        "开始三方合并": "Start the Three-Way Merge",
        "先合并「%@」": "Merge “%@” first",
        "并排比较我的改动、共同基线和服务器改动，逐块决定保留哪一边":
            "Compare my changes, the common base and the server's side by side, and decide block by block",
        "全部用我的": "Keep All Mine",
        "全部用服务器": "Keep All Theirs",
        "其他方式": "Other Options",
        "放弃逐块比较，整个文件采用某一边":
            "Skip the block-by-block review and take one side for the whole file",
        "收起说明": "Hide the explanation",
        "展开说明": "Show the explanation",
        "%d 个文件有冲突（都不能三方合并）":
            "%d file is in conflict (and cannot be merged three-way)|%d files are in conflict (and cannot be merged three-way)",
        "%d 个文件有文本冲突，可以逐块合并":
            "%d file has a text conflict and can be merged block by block|%d files have text conflicts and can be merged block by block",
        "%@ 个文件有冲突，其中 %@ 个可以三方合并":
            "%@ in conflict, %@ of them mergeable three-way",
        "属性冲突和树冲突没有三份可比较的文本，需要整体选一边。用右键菜单「解决冲突」里的策略，或右上角「其他方式」。":
            "Property and tree conflicts have no three texts to compare, so one side has to win outright. Use a strategy from “Resolve conflicts” in the context menu, or “Other Options” above.",
        "三方合并并排显示三份内容：左边是我的改动，中间是双方共同的基线，右边是服务器上的改动。":
            "The three-way merge shows all three versions side by side: my changes on the left, the common base in the middle, the server's changes on the right.",
        "只有两边都改了同一处才需要你决定，其余部分会自动合并。写入前会把当前冲突文件备份到应用支持目录。":
            "You only decide where both sides touched the same place; everything else merges on its own. The current conflict files are backed up to Application Support before anything is written.",
        " 另有 %d 个属性或树冲突不能三方合并，需要整体选一边。":
            " %d more property or tree conflicts cannot be merged three-way and need one side to win.",

        // MARK: - Externals sheet

        "挂载在本工作副本内的其它工作副本。它们的改动在「变更」页会标为「外部」，不能从这里提交。":
            "Other working copies mounted inside this one. Their changes appear as “External” on the Changes page and cannot be committed from here.",
        "重试": "Retry",
        "正在读取仓库属性…": "Reading repository properties…",
        "没有 svn:externals": "No svn:externals",
        "这个工作副本没有挂载外部工作副本。":
            "This working copy mounts no external working copies.",
        "属性只读：svn 不支持直接修改仓库路径的属性，改完需要在工作副本里提交。":
            "Properties are read-only here: svn cannot change a repository path's properties in place, so the edit has to be committed from a working copy.",
        "刷新": "Refresh",
        "关闭": "Close",
        "（工作副本根）": "(working copy root)",

        // MARK: - Lock sheet

        "锁定会阻止其他人提交这些路径，直到锁被解除。":
            "A lock stops other people committing to these paths until it is released.",
        "%d 个路径已被他人锁定": "%d path is already locked by someone else|%d paths are already locked by someone else",
        "普通锁定会失败。要拿到这些路径，必须勾选下面的「强制抢占」。":
            "A normal lock will fail. To take these paths you have to tick “Force take” below.",
        "强制抢占（--force）": "Force take (--force)",
        "移除当前持有人在这个路径上的锁。只有确认对方不再需要时才勾选。":
            "Removes the current holder's lock on this path. Only tick it when you know they no longer need it.",
        "锁定说明（可选）": "Lock comment (optional)",
        "例如：正在修复登录问题": "for example: fixing the sign-in bug",
        "说明会保存在仓库里，其他人看得到。":
            "The comment is stored in the repository and visible to everyone.",
        "其中 %d 项已由本工作副本锁定": "%d of them is already locked by this working copy|%d of them are already locked by this working copy",

        // MARK: - Update preview sheet

        "冲突 #%@": "Conflict #%@",

        "更新「%@」": "Update “%@”",
        "正在向服务器查询…": "Asking the server…",
        "尚未取得服务器状态": "The server's status has not been read yet",
        "未知修订": "Unknown revision",
        "本地 %@": "Local %@",
        "本地 %@ → 服务器 r%@": "Local %@ → server r%@",
        "正在读取服务器上的变更…": "Reading the changes on the server…",
        "这一步只读取，不会改动工作副本。":
            "This step only reads; the working copy is not touched.",
        "无法读取服务器状态": "The server's status could not be read",
        "已是最新": "Already up to date",
        "服务器上没有任何比本地更新的内容（服务器 r%@）。":
            "Nothing on the server is newer than the local copy (server r%@).",
        "服务器上没有任何比本地更新的内容。":
            "Nothing on the server is newer than the local copy.",
        "仍然更新会重新应用目录属性，通常没有必要。":
            "Updating anyway re-applies the folder's properties, which is rarely needed.",
        "本地 %d 个未提交修改": "%d uncommitted local change|%d uncommitted local changes",
        "工作副本根目录的属性也有变更":
            "The working copy root's properties change as well",
        "%d 个文件本地也改过，更新时可能冲突":
            "%d file was also changed locally and may conflict|%d files were also changed locally and may conflict",
        "两边改的是同一处时，svn 会把冲突标记写进文件，并留下冲突副本。更新不会丢失本地内容，但你需要解决冲突后才能提交。":
            "Where both sides changed the same place, svn writes conflict markers into the file and leaves a conflict copy. An update never loses local work, but you have to resolve the conflicts before committing.",
        "可能冲突": "May conflict",
        "本地对该路径有未提交的修改，更新时可能产生冲突":
            "This path has uncommitted local changes and may conflict on update",
        "本地已修改": "Modified locally",
        "本地已新增": "Added locally",
        "本地已删除": "Deleted locally",
        "本地缺失": "Missing locally",
        "本地有冲突": "Conflicted locally",
        "本地未纳入版本控制": "Unversioned locally",
        "预检失败时仍然可以直接更新。":
            "If the pre-check fails you can still update directly.",
        "仍然更新": "Update Anyway",
        "更新只读取服务器并合并到本地；未提交的修改会保留。":
            "An update reads the server and merges into the working copy; uncommitted changes are kept.",
        "仍然更新到 r%@": "Update to r%@ Anyway",
        "更新到 r%@": "Update to r%@",
        "将新增": "Will add",
        "将修改": "Will modify",
        "将删除": "Will delete",

        // MARK: - Commit page

        "有 %d 个未解决的冲突": "%d unresolved conflict|%d unresolved conflicts",
        "解决冲突并标记 resolve 后才能提交。":
            "Resolve them and mark them resolved before committing.",
        "用外部工具解决": "Resolve with External Tool",
        "用「扩展设置」里配置的三方合并工具处理「%@」":
            "Hand “%@” to the three-way merge tool from “Extensions”",
        "已提交为 r%@": "Committed as r%@",
        "已提交": "Committed",
        "包含 %d 个路径": "%d path|%d paths",
        "待提交文件": "Files to commit",
        "全选": "Select All",
        "全不选": "Select None",
        "没有可提交的修改": "Nothing to commit",
        "查看此文件历史…": "Show This File's History…",
        "注解 / 作者…": "Blame…",
        "提交前会再次读取工作副本状态；发现冲突将中止提交，说明与勾选会保留。":
            "The working copy is read again before committing. If a conflict shows up the commit stops, and your message and selection are kept.",
        "提交说明": "Commit message",
        "最近说明": "Recent messages",
        "复用之前的提交说明": "Reuse an earlier commit message",
        "%@ 字符": "%@ characters",
        "差异预览": "Diff preview",
        "已截断": "Truncated",
        "%@ 字节": "%@ bytes",
        "没有文本差异": "No textual difference",
        "可能是二进制文件、新目录，或只有属性变化。":
            "It may be a binary file, a new folder, or a property-only change.",
        "选择文件查看差异": "Select a file to see its diff",
        "点击左侧文件名，提交前再确认一次改了什么。":
            "Click a file name on the left to check once more what you are about to commit.",
        "提交 %d 项": "Commit %d item|Commit %d items",
        "%d 项待提交 · 冲突项已排除": "%d item to commit · conflicted items excluded|%d items to commit · conflicted items excluded",
        "%d 项待提交": "%d item to commit|%d items to commit",
        "他人": "someone else"
    ]
}
