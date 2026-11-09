import Foundation

/// English for the History page, blame and the diff view.
///
/// Revision numbers are never translated or reformatted — they are identifiers
/// — so strings that carry one keep it as `r%@` exactly as svn prints it.
enum StringsHistory {
    static let table: [String: String] = [
        // MARK: - Diff view

        "正在生成差异…": "Generating the diff…",
        "已交给外部工具": "Handed to the External Tool",
        "差异由外部 diff 命令打开，窗口可能已经出现在前台。要改回内置视图，到设置里清空外部 diff 命令。":
            "The diff was opened by the external command, whose window may already be in front. To go back to the built-in view, clear the external diff command in Settings.",
        "没有差异": "No differences",
        "在「变更」页双击文件，或在「历史」页选择修订版本后查看差异。":
            "Double-click a file on the Changes page, or pick a revision on the History page, to see a diff.",
        "差异": "Diff",
        "… 其余 %d 行未显示": "… %d more line not shown|… %d more lines not shown",

        // MARK: - Blame

        "注解": "Blame",
        "正在逐行归属…": "Attributing line by line…",
        "%@ %@ 行": "%@ %@ lines",
        " 等 %d 人": " and %d other",
        " · 其中 %d 行未提交": " · %d of them uncommitted",
        "%@ 行 · %@%@%@": "%@ lines · %@%@%@",
        "无法注解此文件": "This file cannot be blamed",
        "没有可注解的行": "No lines to attribute",
        "行": "Line",
        "修订": "Revision",
        "内容": "Content",
        "其中 %d 行是本地未提交的修改，没有作者归属。":
            "%d of the lines are uncommitted local changes and have no author.|%d of the lines are uncommitted local changes and have no author.",
        "未提交": "Uncommitted",

        // MARK: - History

        "仅显示「%@」的历史": "Show only the history of “%@”",
        "（沿改名/复制向上追溯）": "(follows renames and copies back)",
        "服务器搜索结果：%@ 条匹配「%@」": "Server search: %@ matches for “%@”",
        "匹配提交说明、作者、日期与路径": "Matches commit messages, authors, dates and paths",
        "返回完整历史": "Back to the Full History",
        "尚无历史": "No history yet",
        "没有匹配的修订": "No matching revisions",
        "已加载 %d 条历史，没有一条符合当前筛选。":
            "Loaded %d commit, none of which match the current filter.|Loaded %d commits, none of which match the current filter.",
        "清除筛选": "Clear Filter",
        "在服务器上搜索「%@」": "Search the Server for “%@”",
        "筛选说明、作者、路径、r1234": "Filter messages, authors, paths, r1234",
        "在服务器上搜索全部历史（不只已加载的部分）":
            "Search the server's full history, not just what is loaded",
        "重新读取最新历史": "Reload the latest history",
        "%d 条": "%d commit|%d commits",
        "全部作者": "All authors",
        "提交日期": "Commit date",
        "不限": "Any",
        "清除路径筛选": "Clear the path filter",
        "当前：%@": "Now: %@",
        "清除全部筛选": "Clear All Filters",
        "筛选 · %@": "Filter · %@",
        "按作者、日期或路径筛选已加载的历史":
            "Filter the loaded history by author, date or path",
        "查看此版本差异": "Show This Revision's Diff",
        "复制摘要": "Copy Summary",
        "只看 %@ 的提交": "Only commits by %@",
        "只看包含「%@」的提交": "Only commits touching “%@”",
        "复制为 Markdown，可直接贴进工单或聊天":
            "Copy as Markdown, ready to paste into a ticket or chat",
        "只看该作者的提交": "Show only this revision",
        "时间": "Time",
        "点击路径可只显示它的历史": "Click a path to narrow the history to it",
        "只显示包含该路径的提交": "Show only commits touching this path",
        "最近 7 天": "Last 7 days",
        "最近 30 天": "Last 30 days",
        "最近 90 天": "Last 90 days",
        "最近一年": "Last year"
    ]
}
