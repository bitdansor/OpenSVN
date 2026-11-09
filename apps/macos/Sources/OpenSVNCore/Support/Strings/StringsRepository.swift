import Foundation

/// English for the repository pages: the detail view's tabs and toolbar, the
/// overview, depth, merge, switch, patch and remote-action sheets, the browser,
/// the property editor and the three-way merge editor.
///
/// This is where svn's own vocabulary is densest, so the choices are fixed here
/// and reused everywhere: "mergeinfo" (never translated), "depth", "externals",
/// "record-only", "relocate", "strip count". Flags such as `--force` stay in
/// code font and are never paraphrased.
enum StringsRepository {
    static let table: [String: String] = [
        // MARK: - Detail view: tabs and toolbar

        "变更": "Changes",
        "历史": "History",
        "信息": "Info",
        "分区": "Sections",
        "切换工作副本的分区": "Switch between sections",
        "重新读取工作副本状态": "Re-read the working copy's status",
        "先看服务器上有什么变化，再决定是否更新":
            "See what changed on the server before updating",
        "清理内部锁（svn cleanup）": "Clear the internal lock (svn cleanup)",
        "合并…": "Merge…",
        "切换分支…": "Switch Branch…",
        "合并记录…": "Merge Records…",
        "分支": "Branch",
        "合并、切换分支、查看合并记录":
            "Merge, switch branch, inspect merge records",
        "改深度…": "Change Depth…",
        "应用补丁…": "Apply Patch…",
        "此工作副本": "This working copy",
        "改变稀疏工作副本的深度、应用补丁":
            "Change the depth of a sparse working copy, apply a patch",
        "在 Finder 中显示备份": "Reveal the Backup in Finder",
        "确认操作": "Confirm",
        "分支操作": "Branch operations",
        "查看冲突": "Show the Conflict",

        // MARK: - Overview

        "仓库根": "Repository root",
        "当前修订": "Current revision",
        "节点类型": "Node kind",
        "计划": "Schedule",
        "最后刷新": "Last refreshed",
        "最后修改": "Last changed",
        "文件锁": "File lock",
        "持有者": "Holder",
        "说明": "Comment",
        "创建时间": "Created",
        "正在读取信息…": "Reading the information…",
        "暂无信息": "No information yet",
        "刷新以读取工作副本信息。": "Refresh to read the working copy's information.",
        "更新工作副本": "Update the working copy",
        "清理内部锁": "Clear the internal lock",
        "切换仓库地址…": "Relocate…",
        "svn relocate：仓库换了地址（协议/主机/路径）但内容还是同一个":
            "svn relocate: the repository moved (scheme, host or path) but it is the same repository",
        "查看 svn:mergeinfo，以及某个来源还有哪些修订没合并":
            "Inspect svn:mergeinfo and which revisions a source still owes",
        "切换仓库地址": "Relocate",
        "只用于仓库换了地址但内容没变的情况（换协议、换主机、换路径）。换到另一个仓库会被 svn 拒绝。":
            "Only for a repository that moved without changing (new scheme, host or path). Switching to a different repository is refused by svn.",
        "切换": "Relocate",

        // MARK: - Depth sheet

        "目标": "Target",
        "当前深度": "Current depth",
        "改为": "Change to",
        "深度": "Depth",
        "改深度只影响磁盘上有多少内容，不改动仓库，也不需要提交。排除（exclude）是唯一会删除文件的一项：被排除的路径仓库不再记得，要取回得重新设一个深度。被排除过的目录不能靠「完整」自动回来，得在它自己那一层再设一次。":
            "A depth change only affects how much is on disk. It does not touch the repository and needs no commit. Exclude is the one option that deletes files: an excluded path is forgotten by the repository, and coming back requires setting a depth again. A folder that was excluded does not return with “Fully recursive”; set it at its own level.",
        "改变「%@」的深度": "Change the depth of “%@”",
        "决定这个路径在磁盘上保留多少内容（svn update --set-depth）。":
            "Decides how much of this path stays on disk (svn update --set-depth).",
        "应用中…": "Applying…",
        "应用": "Apply",
        "（工作副本根目录）": "(working copy root)",
        "读取中…": "Reading…",
        "未知": "Unknown",
        "选择要改变深度的工作副本目录":
            "Choose the working copy folder whose depth changes",
        "只能选择这个工作副本里面的目录。":
            "Only folders inside this working copy can be chosen.",
        "改深度失败，详情见弹窗。": "Changing the depth failed; see the dialog.",

        // MARK: - Merge records

        "合并记录": "Merge records",
        "重新读取": "Read Again",
        "读不到合并记录": "The merge records cannot be read",
        "正在读取 svn:mergeinfo…": "Reading svn:mergeinfo…",
        "已记录的合并（svn:mergeinfo）": "Recorded merges (svn:mergeinfo)",
        "这个路径上没有任何合并记录。首次成功合并之后 svn 才会写入 svn:mergeinfo。":
            "There are no merge records on this path. svn only writes svn:mergeinfo after the first successful merge.",
        "某个来源还有哪些没收": "What a source still owes",
        "来源 URL，例如 https://…/trunk": "Source URL, for example https://…/trunk",
        "查询": "Check",
        "svn mergeinfo --show-revs eligible：只读，不碰工作副本，但要访问服务器。":
            "svn mergeinfo --show-revs eligible: read-only, leaves the working copy alone, but does contact the server.",
        "待合并": "Eligible",
        "已合并": "Merged",
        "无": "None",

        // MARK: - Merge sheet

        "跟踪合并（一次来源）": "Tracked merge (one source)",
        "比较两个 URL": "Compare two URLs",
        "全部未合并的修订": "Every eligible revision",
        "指定范围": "A revision range",
        "挑拣单个修订": "Cherry-pick individual revisions",
        "合并到「%@」": "Merge into “%@”",
        "合并只改工作副本：结果还需要一次提交才会进入仓库。":
            "A merge only changes the working copy: the result needs a commit before it reaches the repository.",
        "方式": "Method",
        "合并方式": "Merge method",
        "svn merge SOURCE：由 svn:mergeinfo 决定哪些修订还没合并过。合并一个分支回主干、把主干的修复合到分支，都用这一种。":
            "svn merge SOURCE: svn:mergeinfo decides which revisions are still owed. Merging a branch back into trunk, or trunk's fixes into a branch, both use this form.",
        "svn merge SOURCE1 SOURCE2：把两个 URL 之间的差异应用过来，不依赖 svn:mergeinfo。":
            "svn merge SOURCE1 SOURCE2: applies the difference between two URLs, without consulting svn:mergeinfo.",
        "来源": "Source",
        "来源 URL": "Source URL",
        "对比 URL": "Comparison URL",
        "范围": "Range",
        "起始:结束": "start:end",
        "结束小于起始就是反向合并——这是撤销某段已提交改动的正规做法。":
            "An end below the start is a reverse merge — the proper way to undo a range of committed changes.",
        "修订号": "Revisions",
        "逗号分隔的单个修订号，相当于对每个修订各做一次 -c。":
            "Comma-separated revisions; each one is applied as its own -c.",
        "查询未合并的修订": "Check for Eligible Revisions",
        "svn mergeinfo --show-revs eligible：只读，不碰工作副本":
            "svn mergeinfo --show-revs eligible: read-only, leaves the working copy alone",
        "没有待合并的修订": "No eligible revisions",
        "待合并 r%@": "Eligible: r%@",
        "两 URL 比较不分修订范围：差异就是两个 URL 的当前内容之间的差异。":
            "A two-URL comparison has no revision range: the difference is between the two URLs' current content.",
        "选项": "Options",
        "只记录合并（--record-only）": "Record the merge only (--record-only)",
        "只把修订记进 svn:mergeinfo，不改动任何文件：用于「这段修改我已经手工搬过去了」":
            "Writes the revisions into svn:mergeinfo without touching a file — for “I already moved this change across by hand”",
        "忽略祖先关系（--ignore-ancestry）": "Ignore ancestry (--ignore-ancestry)",
        "不检查两个 URL 是否有复制历史。两 URL 比较常用；跟踪合并会因此失去一部分保护":
            "Do not check whether the two URLs share copy history. Normal for two-URL comparisons; a tracked merge loses some of its protection this way",
        "冲突处理": "Conflict handling",
        "留给我处理（postpone）": "Leave them to me (postpone)",
        "保留我的整份文件（mine-full）": "Keep my whole file (mine-full)",
        "采用来源的整份文件（theirs-full）": "Take the source's whole file (theirs-full)",
        "冲突处保留我的（mine-conflict）": "Keep mine where they clash (mine-conflict)",
        "冲突处采用来源的（theirs-conflict）": "Take the source where they clash (theirs-conflict)",
        "“整份文件”类策略会覆盖本地或来源的完整内容，且没有撤销：冲突被替换掉之后，原本的三份副本只能从备份里找回。":
            "The “whole file” strategies overwrite one side completely and cannot be undone: once the conflict is replaced, the three original copies only exist in the backup.",
        "填写来源后这里会显示这次合并做什么":
            "Once a source is filled in, this area describes what the merge will do",
        "合并中…": "Merging…",
        "合并": "Merge",

        // MARK: - Patch sheet

        "补丁文件": "Patch file",
        "文件": "File",
        "应用到": "Apply to",
        "剥离路径层数：%@": "Strip leading path components: %@",
        "反向应用（--reverse-diff，用来撤销补丁）":
            "Apply in reverse (--reverse-diff, to undo a patch)",
        "匹配时忽略空白差异（--ignore-whitespace）":
            "Ignore whitespace differences when matching (--ignore-whitespace)",
        "给「%@」应用补丁": "Apply a patch to “%@”",
        "把 unidiff 补丁应用到工作副本。补丁可能新增或删除文件。":
            "Applies a unidiff patch to the working copy. A patch can also add or delete files.",
        "预览结果（未修改任何文件）": "Preview the result (no file is changed)",
        "结果": "Result",
        "先点「预览」，看清楚会改动哪些文件，再决定是否应用。":
            "Press “Preview” first to see which files change, then decide.",
        "预览中…": "Previewing…",
        "预览（不修改）": "Preview (no changes)",
        "补丁里的路径原样使用。用 svn diff 在工作副本里生成的补丁通常带着工作副本目录名，需要 1 层。":
            "Paths in the patch are used as they are. A patch produced by `svn diff` inside a working copy usually carries the working copy's folder name, so it needs 1.",
        "去掉路径开头的 %@ 段。例如 doc/a.txt 去掉 1 层后是 a.txt。":
            "Drops %@ leading components from each path. For example doc/a.txt becomes a.txt after 1.",
        "选择要应用的补丁文件": "Choose the patch file to apply",
        "补丁没有完全应用，详情见上方结果。":
            "The patch did not apply completely; see the result above.",
        "有目标找不到，通常说明「剥离路径层数」不对。看一眼补丁开头的 --- 行是怎么写的，再调整这个数字。":
            "Some targets were not found, which usually means the strip count is wrong. Look at the `---` lines at the top of the patch and adjust the number.",
        "没有匹配上的片段被写进了同目录的 .svnpatch.rej 文件，原文件保持不变。可以手工合并，或者用「还原」放弃这次改动。":
            "The hunks that did not match were written to a `.svnpatch.rej` file beside the original, which is unchanged. Merge them by hand, or use “Revert” to drop the change.",
        "这个补丁没有匹配到任何文件。": "This patch matched no file.",
        "预览不会改动任何文件。": "A preview changes no file.",
        "打开「变更」页可以看到这些改动，提交前请先看一眼。":
            "The changes are visible on the Changes page; take a look before committing.",

        // MARK: - Remote action (copy, move, mkdir, delete, import)

        "这是一次提交，会立刻写进仓库历史。":
            "This is a commit: it goes into the repository's history immediately.",
        "源": "Source",
        "完整 URL": "Full URL",
        "会显示在历史里": "Shown in the history",
        "tag 就是一次目录 copy：`svn copy trunk tags/v1.0`。svn 没有单独的 tag 命令，这个约定就是全部。":
            "A tag is just a folder copy: `svn copy trunk tags/v1.0`. svn has no separate tag command — that convention is the whole feature.",
        "删除后路径会从 HEAD 消失，所有工作副本下次更新时都会收到删除。svn 保留历史，但找回它需要知道修订号并执行命令。":
            "Deleting removes the path from HEAD, and every working copy receives the deletion on its next update. svn keeps the history, but getting the path back means knowing a revision and running a command.",

        // MARK: - Repository browser

        "操作失败": "The operation failed",
        "新建目录…": "Create Folder…",
        "在此创建 tag…": "Create a Tag Here…",
        "导出此目录…": "Export This Folder…",
        "导入本地目录…": "Import a Local Folder…",
        "仓库操作": "Repository actions",
        "新建目录、打 tag、导出、导入": "Create folders, tag, export, import",
        "上一级": "Up One Level",
        "正在读取仓库…": "Reading the repository…",
        "空目录": "Empty folder",
        "这个目录里没有任何文件或子目录。":
            "There are no files or subfolders in this folder.",
        "双击进入": "Double-click to open",
        "进入": "Open",
        "创建 tag…": "Create Tag…",
        "复制到…": "Copy To…",
        "移动到…": "Move To…",
        "导出…": "Export…",
        "%@ 个目录 · %@ 个文件": "%@ folders · %@ files",
        "选择一个尚未纳入版本控制的本地目录":
            "Choose a local folder that is not under version control yet",
        "导入「%@」": "Import “%@”",
        "目标路径与提交说明。导入是一次提交，目标不能已存在。":
            "Destination path and commit message. An import is a commit, and the destination must not exist.",
        "目录名": "Folder name",
        "选择一个空目录：svn export 不会覆盖已有文件":
            "Choose an empty folder: svn export never overwrites existing files",

        // MARK: - Switch sheet

        "切换到的 URL": "Switch to URL",
        "修订版本": "Revision",
        "外挂工作副本保持不动（--ignore-externals）":
            "Leave external working copies alone (--ignore-externals)",
        "覆盖未纳入版本控制的同名文件（--force）":
            "Overwrite unversioned files of the same name (--force)",
        "--force 会让未纳入版本控制的同名文件被切换后的内容替换掉，那些文件没有任何备份。":
            "--force lets the switched content replace unversioned files of the same name, and those files have no backup at all.",
        "当前地址：%@": "Current URL: %@",
        "只想换协议、主机或路径、而内容还是同一个仓库？那是「信息」页的「切换仓库地址」（relocate），不是这里。svn 会校验仓库 UUID，切到另一个仓库会失败。":
            "Only changing the scheme, host or path while it stays the same repository? That is “Relocate” on the Info page, not this. svn checks the repository UUID, so switching to a different repository fails.",
        "切换「%@」": "Switch “%@”",
        "把工作副本整体指向同一仓库内的另一个 URL。":
            "Points the whole working copy at another URL in the same repository.",
        "填写目标 URL 后这里会显示这次切换做什么":
            "Once a target URL is filled in, this area describes what the switch will do",
        "切换中…": "Switching…",

        // MARK: - Property editor

        "正在读取属性…": "Reading properties…",
        "这个路径没有设置任何属性。": "No properties are set on this path.",
        "要忽略文件，在下方添加 svn:ignore，每行一个通配符模式；也可以在「变更」页右键未纳入版本控制的文件，直接选择「忽略」。":
            "To ignore files, add svn:ignore below with one pattern per line — or right-click an unversioned file on the Changes page and choose “Ignore”.",
        "属性名，例如 custom:owner": "Property name, for example custom:owner",
        "值": "Value",
        "自定义属性必须带命名空间，例如 custom:owner。以 svn: 开头的是 Subversion 的保留属性。":
            "A custom property needs a namespace, for example custom:owner. Anything starting with `svn:` is reserved by Subversion.",
        "属性是版本化元数据，会随下一次提交一起提交；改动可以用「还原」撤销。":
            "Properties are versioned metadata: they commit with the next commit, and a change can be undone with “Revert”.",
        "内部": "Internal",
        "Subversion 内部使用的属性，只读": "A property Subversion uses internally; read-only",
        "每行一个通配符模式": "One pattern per line",
        "撤销": "Undo",
        "移除这个属性（可用「还原」恢复）":
            "Remove this property (recoverable with “Revert”)",

        // MARK: - Three-way merge editor

        "没有需要决定的冲突": "Nothing left to decide",
        "两边的改动互不重叠，直接写入即可。":
            "The two sides changed different places; writing the result is enough.",
        "看三栏": "Read the three columns",
        "左边是我的文件，中间是双方共同的基线，右边是服务器上的版本。":
            "Mine on the left, the common base in the middle, the server's version on the right.",
        "每处选一边": "Pick a side for each hunk",
        "只有两边都改了同一处才需要决定；单边改动已经自动采用。":
            "You only decide where both sides changed the same place; one-sided changes are already taken.",
        "写回文件": "Write it back",
        "点「写入并标记已解决」，文件内容就是你的决定，冲突随之解除。":
            "Press “Write and Mark Resolved”; the file becomes exactly what you decided, and the conflict is gone.",
        "%@ · 无冲突区域": "%@ · no conflicting region",
        "%@ · 共 %@ 处冲突，%@ 处待决定":
            "%@ · %@ conflicts, %@ still undecided",
        "写入前会把当前的冲突文件备份到应用支持目录，写错了可以找回。":
            "The current conflict files are backed up to Application Support before writing, so a mistake can be recovered.",
        "还有 %d 处没有决定 —— 每一处都必须选一边，合并结果才不会丢内容。":
            "%d hunk is still undecided — every one needs a side, or the merge result loses content.|%d hunks are still undecided — every one needs a side, or the merge result loses content.",
        "写入并标记已解决": "Write and Mark Resolved",
        "写入合并结果并以 --accept=working 解决冲突":
            "Write the merge result and resolve the conflict with --accept=working",
        "还有冲突未决定": "Some conflicts are undecided",
        "基线 %@ 行 · 我的 %@ 行 · 服务器 %@ 行":
            "Base %@ lines · mine %@ lines · theirs %@ lines",
        "待决定": "Undecided",
        "我的": "Mine",
        "基线": "Base",
        "服务器": "Theirs",
        "采用": "Take",
        "两者（我的在前）": "Both (mine first)",
        "（删除）": "(deleted)",
        "这里原本没有内容，两边各自新增了不同的内容。":
            "Nothing was here before; both sides added different content.",
        "我删掉了这段，服务器改动了它。":
            "I deleted this; the server changed it.",
        "服务器删掉了这段，我改动了它。":
            "The server deleted this; I changed it.",
        "两边改了同一处，而且内容不同 —— 这是唯一需要你决定的情况。":
            "Both sides changed the same place, differently — this is the only case that needs you."
    ]
}
