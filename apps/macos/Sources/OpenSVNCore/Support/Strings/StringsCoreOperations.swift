import Foundation

/// English for the operation layer: the summaries and confirmations `SVNService`
/// builds before a command runs, plus the update path's failure messages.
///
/// These strings reach the user through three different surfaces — the confirm
/// sheet, the task centre and the error banner — so they are phrased to stand
/// alone in all three: no "点击上方", no pronouns pointing at a dialog.
enum StringsCoreOperations {
    static let table: [String: String] = [
        // MARK: - Checkout, update, depth

        "\n\n… 差异过大，已截断显示（共 %@ 字节）。":
            "\n\n… the diff was too large and has been truncated (%@ bytes in total).",
        "完整检出（含子目录）": "Full checkout (including subfolders)",
        "svn %@ 不支持按需获取原始副本（Pristines on Demand），需要 1.15 或更高版本":
            "svn %@ does not support Pristines on Demand; 1.15 or later is required",
        "目标已存在且不是目录：%@": "The destination exists and is not a folder: %@",
        "目标目录非空，无法检出：%@":
            "The destination folder is not empty, so it cannot be checked out into: %@",
        "检出到 %@": "Check out into %@",
        "改深度和指定修订不能在同一次更新里做。svn 会把两者一起应用，若该路径在目标修订中不存在，它会被直接删掉。":
            "A depth change and a specific revision cannot be combined in one update. svn applies both at once, so a path that does not exist at the target revision is deleted.",
        "改深度到 %@：%@": "Set the depth to %@: %@",
        "更新 %@": "Update %@",
        " 等 %@ 项": " and %@ more",
        "这个目录里还有未纳入版本控制的文件（%@%@），不能整体排除。":
            "This folder still holds unversioned files (%@%@), so it cannot be excluded as a whole.",
        "svn 会把这些文件留在磁盘上、同时丢掉目录的版本控制信息，工作副本还可能被锁住。":
            "svn would leave those files on disk while dropping the folder's versioning, and the working copy could end up locked.",
        "请先移走或删除它们，再改深度。":
            "Move or delete them first, then change the depth.",

        // MARK: - Add, delete, revert, commit

        "添加 %d 个路径": "Add %d path|Add %d paths",
        "删除「%@」并纳入版本控制": "Delete “%@” from version control",
        "这些文件会从磁盘和下次提交中移除。":
            "These files are removed from disk and from the next commit.",
        "以下 %d 项本地内容会一并丢失：\n":
            "%d local item will be lost as well:\n|%d local items will be lost as well:\n",
        "删除 %d 个路径": "Delete %d path|Delete %d paths",
        "还原 %d 个路径的本地修改":
            "Revert local changes in %d path|Revert local changes in %d paths",
        "所选路径没有可还原的本地修改。":
            "The selected paths have no local changes to revert.",
        "以下本地修改会被丢弃，且无法恢复：\n":
            "These local changes are discarded and cannot be recovered:\n",
        "还原 %d 个路径": "Revert %d path|Revert %d paths",
        "没有选择要提交的路径": "No paths are selected to commit",
        "提交说明不能为空": "The commit message cannot be empty",
        "提交 %d 个路径": "Commit %d path|Commit %d paths",
        "存在未解决的冲突：%@": "Unresolved conflicts remain: %@",
        "请先解决冲突并标记 resolve 后再提交。":
            "Resolve them and mark them resolved before committing.",

        // MARK: - Locking

        "没有选择要锁定的路径": "No paths are selected to lock",
        "「强制锁定」会抢占他人持有的锁":
            "“Force lock” takes a lock that someone else holds",
        "持有者将无法提交该路径，直到他注意到锁已易主。":
            "The holder cannot commit that path until they notice the lock has changed hands.",
        "锁定 %d 个路径": "Lock %d path|Lock %d paths",
        "没有选择要解锁的路径": "No paths are selected to unlock",
        "「强制解除」会移除他人持有的锁":
            "“Force unlock” removes a lock that someone else holds",
        "对方可能正在编辑该文件；解除后两人的提交都可能互相覆盖。":
            "They may be editing the file right now; once unlocked, either commit can overwrite the other's work.",
        "解锁 %d 个路径": "Unlock %d path|Unlock %d paths",

        // MARK: - Cleanup, resolve, properties, ignore

        "清理 %@": "Clean up %@",
        "「%@」会覆盖本地或服务器端内容":
            "“%@” overwrites local or server content",
        "解决 %d 个冲突": "Resolve %d conflict|Resolve %d conflicts",
        "设置属性 %@": "Set property %@",
        "删除属性 %@": "Delete property %@",
        "忽略规则不能为空": "The ignore pattern cannot be empty",
        "无法写入临时文件来传递属性值：%@":
            "Could not write the temporary file used to pass the property value: %@",

        // MARK: - Repository-side operations

        "已创建 %@": "Created %@",
        "已复制到 %@": "Copied to %@",
        "已移动到 %@": "Moved to %@",
        "删除仓库路径需要确认：%@":
            "Deleting a repository path needs confirmation: %@",
        "已删除 %@": "Deleted %@",
        "已导入 %@": "Imported %@",
        "合并到 %@": "Merge into %@",
        "切换 %@ 到 %@": "Switch %@ to %@",
        "应用补丁会修改工作副本里的文件（补丁也可能新增或删除文件）。请先预览，再确认应用。":
            "Applying a patch changes files in the working copy, and may add or delete files. Preview it, then confirm.",
        "应用补丁 %@": "Apply patch %@",
        "目标目录非空，无法在此创建仓库：%@":
            "The destination folder is not empty, so a repository cannot be created there: %@",
        "创建本地仓库 %@": "Create local repository %@",
        "仓库操作需要提交说明：svn 会把它写进历史，不能留空":
            "A repository operation needs a commit message: svn records it in history, so it cannot be empty",

        // MARK: - Authentication

        "需要登录 %@": "Sign in to %@",
        "需要登录": "Sign in",
        "找不到 svnadmin：它应与 svn 位于同一目录":
            "svnadmin was not found; it should sit next to svn",
        "svnadmin 执行失败": "svnadmin failed",
        "svn %@ 不支持从 stdin 读取密码，需要 1.10 或更高版本":
            "svn %@ cannot read a password from stdin; 1.10 or later is required",

        // MARK: - Download

        "这个版本的安装包没有可校验的摘要，只能手动下载。":
            "This release's installer has no digest to verify, so it can only be downloaded by hand.",
        "更新包超过 %@，已停止下载。":
            "The update is larger than %@, so the download stopped.",
        "下载已取消。": "The download was cancelled.",
        "下载更新包失败：%@": "Downloading the update failed: %@",
        "下载服务器返回了 HTTP %@。": "The download server returned HTTP %@.",
        "更新包大小不符（应为 %@ 字节，实际 %@ 字节），已丢弃。":
            "The update is the wrong size (%@ bytes expected, %@ received) and was discarded.",
        "更新包校验不一致，文件可能损坏或不是发布者上传的那一份，已丢弃。":
            "The update failed verification: the file is damaged, or it is not the copy the publisher uploaded. It was discarded.",
        "无法写入暂存目录：%@": "Could not write to the staging folder: %@",
        "服务器结束了下载，但没有返回文件。":
            "The server ended the download without returning a file.",

        // MARK: - Install

        "更新包里没有找到应用（%@）。": "No app was found inside the update (%@).",
        "无法解开更新包：%@": "Could not unpack the update: %@",
        "更新包的代码签名无效：%@": "The update's code signature is invalid: %@",
        "当前应用是这个 Developer ID 团队签名的，但更新包没有团队标识，已拒绝安装。":
            "The running app is signed by a Developer ID team, but the update carries no team identifier, so it was refused.",
        "更新包的签名团队是 %@，与当前应用的 %@ 不一致，已拒绝安装。":
            "The update is signed by team %@, not %@ as the running app is, so it was refused.",
        "更新包的标识是 %@，不是 %@，已拒绝安装。":
            "The update's bundle identifier is %@, not %@, so it was refused.",
        "更新包版本是 %@，与发布信息里的 %@ 不一致，已拒绝安装。":
            "The update is version %@, not %@ as the release says, so it was refused.",
        "没有权限替换 %@。请把它移到可写的位置，或手动下载安装。":
            "No permission to replace %@. Move it somewhere writable, or install by hand.",
        "无法启动安装助手：%@": "Could not start the installer helper: %@",
        "（缺失）": "(missing)",

        // MARK: - Signed manifest

        "这个发布没有附带签名清单（SHA256SUMS 与 .sig），无法确认安装包来源。":
            "This release ships no signed manifest (SHA256SUMS and .sig), so the installer's origin cannot be confirmed.",
        "当前构建没有内置更新公钥，无法校验发布清单。":
            "This build has no update public key compiled in, so the manifest cannot be verified.",
        "发布清单格式不正确，已拒绝安装。":
            "The release manifest is malformed, so the install was refused.",
        "发布清单的签名无效，安装包可能不是发布者上传的那一份，已拒绝安装。":
            "The manifest signature is invalid — the installer may not be the publisher's upload — so the install was refused.",
        "发布清单里没有 %@ 的摘要，已拒绝安装。":
            "The manifest lists no digest for %@, so the install was refused.",
        "发布清单里的摘要与发布服务器给出的摘要不一致，已拒绝安装。":
            "The manifest's digest differs from the one the release server reports, so the install was refused.",
        "发布清单元数据超过 %@ 字节，已拒绝读取。":
            "The manifest is larger than %@ bytes, so it was not read.",
        "无法读取发布清单：%@": "Could not read the release manifest: %@"
    ]
}
