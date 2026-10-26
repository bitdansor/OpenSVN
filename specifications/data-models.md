# 数据模型契约

> 状态：v0.1（与 `apps/macos/Sources/OpenSVNCore/Models/` 一致）
> 关联：`specifications/svn-operations.md`（产生这些模型的调用）、`specifications/ui-behavior.md`（这些字段在界面上怎么呈现）

本文件定义两端共享的**字段语义**。字段名可随语言习惯调整（Swift 的 `item`，C++ 的 `text_status`），但含义、取值集合、组合规则必须一致。

## 1. 为什么把冲突和锁拆开

规范 §6 明确：**不得用单个布尔字段承载冲突信息**。实际数据里，一个路径可以同时是：

- 文本冲突（`item="conflicted"`）
- 属性冲突（`props="conflicted"`）
- 树冲突（`tree-conflicted="true"`）

而“锁”也有两种完全不同的东西：

| 锁 | 含义 | 处理方式 |
|---|---|---|
| 仓库文件锁 `repositoryLock` | 服务器上的 `svn lock`，带 token / owner / comment | `unlock`，或提交时自动释放 |
| 工作副本内部锁 `isWorkingCopyLocked` | 本地 `svn cleanup` 要清理的锁 / 未完成操作 | `cleanup` |

二者混为一谈会导致：把“别人锁了文件”提示成“请执行 Cleanup”，用户按提示操作后毫无作用。

## 2. StatusEntry

来源：`svn status --xml` 的 `<entry>` / `<wc-status>`。

| 字段 | 类型 | 来源 | 说明 |
|---|---|---|---|
| `path` | string | `entry@path` | 原样保留，可能是绝对或相对路径 |
| `item` | WCItemStatus | `wc-status@item` | 文本状态 |
| `properties` | WCItemStatus | `wc-status@props` | 属性状态，独立字段 |
| `revision` | int64? | `wc-status@revision`，回退 `entry@revision` | 基线修订 |
| `isCopied` | bool | `entry@copied` / `wc-status@copied` | 是否带历史复制 |
| `conflicts.text` | flag | `item == conflicted` | |
| `conflicts.property` | flag | `props == conflicted` | |
| `conflicts.tree` | flag | `wc-status@tree-conflicted == "true"` | |
| `repositoryLock` | object? | `wc-status/lock` | token / owner / comment / created |
| `isWorkingCopyLocked` | bool | `item == incomplete`，或错误映射 | 本地锁信号 |
| `changelist` | string? | `entry@changelist` | |
| `commit` | object? | `wc-status/commit` | revision / author / date |
| `depth` | string? | `wc-status@depth` | |

`WCItemStatus` 取值：`added, conflicted, deleted, external, ignored, incomplete, invalid, merged, missing, modified, none, normal, obstructed, replaced, unversioned`，外加 `unknown(raw)`。**遇到未知 token 必须保留原值**，不得丢弃或映射为 `normal`。

派生字段（非存储）：

- `hasConflicts = !conflicts.isEmpty`
- `category`：冲突优先，其次文本状态；`missing` 归入 `deleted` 分组。

`StatusSnapshot`：`target`、`entries`、`workingCopyRevision`（条目修订的最小值，仅作参考）。

## 3. ConflictFlags

位标志，可组合。序列化为稳定有序数组：`["text", "property", "tree"]` 的子集。契约测试按该顺序比较。

## 4. LogEntry / ChangedPath

来源：`svn log --xml -v`。

| 字段 | 说明 |
|---|---|
| `revision` | int64 |
| `author` | 空 `<author/>` 视为 nil，不保留空串 |
| `date` | 绝对时刻（UTC 解析），显示层本地化 |
| `message` | 原样，保留换行；空为 `""` |
| `changedPaths[].path` | 仓库内路径（`/trunk/...`） |
| `changedPaths[].action` | `A/D/M/R`，未知为 `?` |
| `changedPaths[].copyFromPath/Revision` | 复制来源，缺省 nil |

分页：`LogPage.hasMore = entries.count >= limit`。下一页 `-r <oldest-1>:1`。

## 5. InfoReport / RepositoryInfo

来源：`svn info --xml`。多 `<entry>` 时 `entries[0]` 为主。

| 字段 | 说明 |
|---|---|
| `path` | 目标路径（原样） |
| `url` | 完整 URL |
| `repositoryRoot` / `repositoryUUID` | 仓库标识 |
| `revision` | 当前修订 |
| `kind` | `file` / `dir` / `none` |
| `schedule` / `depth` | 工作副本调度信息 |
| `workingCopyRoot` | `wc-info/wcroot-abspath`，URL 目标时为 nil |
| `lastChanged*` | commit 节点 |
| `repositoryLock` | `<entry>/<lock>`，URL 目标也可能有 |

## 6. 错误模型

`SVNError`：`code`（应用错误码）、`message`（已脱敏、可直接展示）、`diagnosticOutput`（已脱敏）、`svnCode`（如 `E155004`）、`exitCode`。详见 `error-codes.md`。

## 7. 规范化与契约比对

两端对同一 fixture 产出 JSON 时，必须：

1. 字段按字典序输出；
2. 数组顺序保持解析顺序（status 条目按 svn 输出顺序，不做二次排序）；
3. 日期统一为 UTC ISO-8601，带毫秒（`2026-10-18T04:35:56.116Z`）；
4. 空值统一为 `null`，不省略字段；
5. 路径不做 `realpath` 归一化（保留 svn 原样输出）；
6. 布尔值用 `true/false`，不用 0/1。

fixture 采集时必须记录 `svn --version --quiet`；不同 svn 版本不得混用同一组 fixture。当前记录版本见 `testdata/README.md`。

## 8. 模型演进规则

- 新增字段：允许，默认值必须等价于旧行为。
- 新增状态枚举：必须走 `unknown(raw)` 兜底路径，旧版本客户端不得崩溃。
- 删除字段 / 改变语义：需要 `compatibility.md` 与两端同步升级，不能单端先改。
