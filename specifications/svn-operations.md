# SVN 操作契约

> 状态：v0.1（macOS 已实现，Windows 待实现）
> 关联：`OpenSVN_开发规划.md` §6、`OpenSVN_开发执行计划.md` S2-1 / S3-1
> 实现：`apps/macos/Sources/OpenSVNCore/Services/SVNService.swift`

本文是**行为契约**，不是某个平台的实现说明。两端的接口语义、前置条件、副作用、失败后状态必须一致；实现可以是 Swift、C++ 或任何语言。

## 0. 所有操作的共同规则

| 规则 | 内容 |
|---|---|
| R1 进程 | 一律以独立参数数组启动子进程，禁止 shell 拼接；路径作为单个 argv 元素传递 |
| R2 凭据 | 密码只通过 stdin（`--password-from-stdin`）传递；argv、日志、设置中不得出现 |
| R3 危险操作 | 服务层要求 `confirmed: Bool` 入参，界面不是唯一防线 |
| R4 写串行 | 同一工作副本根（最近的 `.svn` 目录）上的写操作必须串行 |
| R5 不升级 | 不自动升级工作副本格式；遇到未知格式直接报错 |
| R6 异步 | 所有操作异步、可取消、可报告进度 |
| R7 机读 | 解析 `--xml` 输出；只有进度/摘要可以读人类可读文本 |
| R8 编码 | 子进程 locale 必须为 UTF-8（macOS 实测 `LC_ALL=C` 会导致 `E000022`，中文路径不可用） |

通用参数（由服务层统一附加，调用方不得重复）：

```text
--non-interactive --no-auth-cache [--username <user> --password-from-stdin]
```

`--no-auth-cache` 是刻意的：凭据只由 OpenSVN 写入系统钥匙串，不让 svn 在 `~/.subversion/auth` 再存一份。

## 1. 方法表

| 方法 | 语义 | 网络 | 写工作副本 | 需确认 | 幂等 |
|---|---|---|---|---|---|
| `checkout(url,to,revision,depth)` | 检出到空目录 | 是 | 创建 | 否 | 目标非空时拒绝 |
| `update(at,revision)` | 更新工作副本 | 是 | 是 | 否 | 是 |
| `status(at,includeIgnored)` | 读取状态 | 否 | 否 | 否 | 是 |
| `add(paths,force,noIgnore)` | 纳入版本控制 | 否 | 是 | 否 | 重复 add 报错 |
| `previewDelete(paths)` | 描述删除后果 | 否 | 否 | — | 是 |
| `delete(paths,confirmed)` | 删除并排入提交 | 否 | 是 | **是** | 否 |
| `previewRevert(paths)` | 描述还原后果 | 否 | 否 | — | 是 |
| `revert(paths,confirmed)` | 丢弃本地修改 | 否 | 是 | **是** | 是 |
| `commit(paths,message)` | 提交选定路径 | 是 | 是 | 否 | 否 |
| `diffWorkingCopy(at)` | 本地差异 | 否 | 否 | 否 | 是 |
| `diff(at,revision)` | 某修订的差异 | 是 | 否 | 否 | 是 |
| `log(at,limit,from)` | 历史 | 是 | 否 | 否 | 是 |
| `info(at)` | 仓库/工作副本信息 | 否* | 否 | 否 | 是 |
| `cleanup(at)` | 清理内部锁 | 否 | 是 | 否 | 是 |
| `resolve(paths,strategy,confirmed)` | 解决冲突 | 否 | 是 | 视策略 | 否 |

\* `info` 针对工作副本路径时只读本地 `.svn`；针对 URL 时访问网络。

### 1.1 checkout

- 前置：目标不存在，或存在且为空目录。否则返回 `SVN-9001`。
- 副作用：创建完整工作副本；失败可能留下部分目录，**不得**自动删除用户目录。
- 深度：`infinity` / `immediates` / `files` / `empty`。
- 序列化键：目标绝对路径。

### 1.2 update

- 前置：目标在工作副本内。
- 成功判据：退出码 0；新修订号通过随后一次 `svn info --xml` 读取，而不是解析 “Updated to” 文本。
- 摘要：从输出行提取 `A/D/U/C/G` 首列，仅用于展示。
- 冲突：`update` 不解决冲突，只报告。冲突详情以 `status --xml` 为准。
- 中断：可能留下混合修订版本与内部锁，用户需执行 `cleanup`。这是 `cleanup` 存在的主要理由。

### 1.3 status

- `--xml`；`includeIgnored: false` 时不加 `--no-ignore`。
- 返回的路径可能是绝对路径（传入绝对路径时）或相对路径（传入相对目标时），调用方不得假设。
- 不访问网络（`-u` 不在 MVP 内）。

### 1.4 add

- 对未纳入版本控制的路径有效；`force` 允许添加被忽略项。
- 不递归处理已版本化目录中的忽略文件，除非 `noIgnore`。
- 重复 `add` 由 svn 报错，服务层不静默吞掉。

### 1.5 delete / revert（危险操作）

- `confirmed == false` 时：
  1. 重新扫描状态生成 `OperationPreview`（影响路径、将丢失的本地修改、风险等级）；
  2. 抛出 `SVN-0501 confirmationRequired`，附带预览文本；
  3. **不执行任何写操作**。
- `confirmed == true` 时执行，并在完成后由调用方刷新状态。
- `revert` 不影响未纳入版本控制的文件；预览必须写明这一点，避免用户误以为“全部清空”。
- `delete` 会立即删除磁盘文件（无 `--keep-local`），预览必须列出被删除的本地修改。

### 1.6 commit

- 前置校验（在服务层，任何入口都一样）：
  1. 路径非空；
  2. 提交说明去除首尾空白后非空，否则 `SVN-9001`；
  3. 逐个路径重新 `status`，发现冲突立即 `SVN-0301 conflictRemains`，**不提交**。
- 参数：`-m <message> --encoding UTF-8`，说明以单个 argv 传递（非机密）。
- 成功判据：退出码 0 且输出含 `Committed revision N`；无法解析时 revision 为 nil，但操作仍视为成功。
- 提交后不自动 `update`；由界面决定。

### 1.7 resolve（不可逆）

`svn resolve --accept=<arg>` 的语义必须逐项解释，界面不能只显示参数名：

| 策略 | svn 参数 | 后果 | 可逆 |
|---|---|---|---|
| 保留工作副本 | `working` | 保留磁盘内容（可能仍含冲突标记），仅清除冲突状态 | 是（可再改） |
| 全部用我的 | `mine-full` | 丢弃服务器端修改 | **否** |
| 全部用服务器的 | `theirs-full` | 丢弃全部本地修改 | **否** |
| 回到基线 | `base` | 丢弃本地与该次服务器修改 | **否** |

契约：三种不可逆策略必须 `confirmed: true`；`working` 不要求确认。批量解决（>1 路径）必须二次确认。

**解决前备份（服务层，非界面层）**：调用 svn 之前，把工作文件及 svn 留下的冲突副本
（`.mine` / `.r<N>` / `.working` / `.orig` / `.rej`）复制到
`~/Library/Application Support/OpenSVN/ConflictBackups/<工作副本名>-<hash>/<UTC 时间戳>-<策略>/`。
备份失败立即中止并返回 `SVN-0303`——不允许在没有退路的情况下覆盖文件。备份在写锁内完成，
避免"备份的是旧状态、解决的是新状态"。每个工作副本只保留最近 10 次。

**解决后校验**：重新读取文件，行首出现 `<<<<<<<`、`>>>>>>>` 或 `|||||||` 即判定仍有冲突标记，
由 `ResolveOutcome.pathsWithResidualMarkers` 返回，界面必须明确提示"直接提交会把标记写进仓库"。
单独一行 `=======` 不算（reStructuredText 的标题下划线会误报）。二进制、非 UTF-8、超过 8 MB 的文件跳过并如实说明。

### 1.8 cleanup

- 无网络，幂等。
- 不删除用户文件；“清理”仅指 `.svn` 内部锁与未完成事务。
- 若 `cleanup` 后仍报 `E155004`，错误映射必须提示“工作副本可能损坏，请备份后重新检出”，而不是反复重试。

## 2. 中断恢复（操作日志）

写操作（checkout / update / commit / add / delete / revert / resolve / cleanup）在**启动子进程之前**落一条记录，在子进程返回后删除。启动时仍然存在的记录，按定义就是"上次没有结果的操作"。

| 项 | 契约 |
|---|---|
| 位置 | `~/Library/Application Support/OpenSVN/journal.json` |
| 内容 | 操作类型、工作副本绝对路径、一句摘要、开始时间、启动标识（UUID）、PID。**不含凭据、不含命令行、不含提交说明。** |
| 写入 | `Data.write(options: .atomic)`（临时文件 + rename）。断电不得留下半个 JSON。 |
| 操作失败 | 记录在 `finish` 中删除。**失败不是中断**：结果已知，不该弹恢复提示。 |
| 崩溃 / 强杀 | 记录保留，下次启动出现在恢复横幅里。 |
| 文件损坏 | 重命名为 `journal.corrupt-<时间戳>.json` 保留，不删除；应用照常启动。 |
| 上限 | 50 条，按开始时间保留最新。超出说明在反复崩溃。 |
| 恢复动作 | 默认建议 `svn cleanup`，然后刷新状态。**commit 绝不建议直接重试**——它可能已经在服务器端生效。 |

判定"上次"的依据是启动标识（UUID），不是 PID：PID 会被复用，两个不同的进程可能拿到同一个号。

恢复界面只负责把工作副本带回"可读状态"；是否重试由用户在看到真实状态后决定。这不属于"自动修复"，也不允许悄悄重放任何写操作。

## 3. 取消语义

| 操作 | 取消后工作副本状态 | 用户可见说明 |
|---|---|---|
| `update` | 可能为混合修订版本，可能存在内部锁 | “操作已取消，建议执行 Cleanup” |
| `commit` | 服务器端要么已提交要么未提交；本地不改变 | “请查看历史确认是否已提交” |
| `checkout` | 目录可能不完整 | “可删除目标目录后重新检出” |
| `status` / `info` / `log` / `diff` | 无副作用 | “操作已取消” |

实现约束：取消先 `SIGTERM`，2 秒后 `SIGKILL`；必须等待子进程退出后再返回，避免留下孤儿进程。

## 4. 凭据流程

1. 首次尝试不带凭据。
2. 若 stderr 映射为认证类错误（`E170001` / `E215004` 等）：
   - 若使用的是钥匙串中的旧凭据 → 删除该条目并报 `authenticationRequired`；
   - 若未使用凭据 → 直接报 `authenticationRequired`。
3. 界面收集用户名/密码 → 服务层以 `--password-from-stdin` 重试**一次**。
4. 成功后才写入钥匙串；失败不保存。
5. 不做自动无限重试。

## 5. 未实现的接口（后续版本）

`switch`、`merge`、`lock` / `unlock`、`export`、`blame`、`cat`。契约预留：方法名、错误码、确认策略在设计时补入本文，而不是先写实现后补文档。
