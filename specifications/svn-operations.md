# SVN 操作契约

> 状态：v0.1（macOS 已实现；Windows 核心已实现，真实 svn 验证待补）
> 关联：`specifications/data-models.md`（输出模型）、`specifications/error-codes.md`（失败语义）
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
| `checkout(url,to,revision,depth,storePristines)` | 检出到空目录 | 是 | 创建 | 否 | 目标非空时拒绝 |
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
| `log(at,limit,from,newerThanOrEqual)` | 历史 | 是 | 否 | 否 | 是 |
| `log(at,search)` | 全文搜索历史 | 是 | 否 | 否 | 是 |
| `blame(at,revision)` | 逐行归属 | 是 | 否 | 否 | 是 |
| `info(at)` | 仓库/工作副本信息 | 否* | 否 | 否 | 是 |
| `cleanup(at)` | 清理内部锁 | 否 | 是 | 否 | 是 |
| `resolve(paths,strategy,confirmed)` | 解决冲突 | 否 | 是 | 视策略 | 否 |
| `properties(at,recursive)` | 读取全部属性 | 否 | 否 | 否 | 是 |
| `setProperty(name,value,targets)` | 设置属性 | 否 | 是 | 否 | 是 |
| `deleteProperty(name,targets)` | 删除属性 | 否 | 是 | 否 | 是 |
| `ignore(paths)` | 按文件名追加 `svn:ignore` | 否 | 是 | 否 | 是 |
| `lock(paths,comment,steal)` | 取仓库锁 | 是 | 是（写 lock token） | 仅 `steal` | 否（重复锁报错） |
| `unlock(paths,breakLock)` | 释放仓库锁 | 是 | 是 | 仅 `breakLock` | 否（无锁报错） |
| `locks(at)` | 读取仓库锁（含他人持有） | 是 | 否 | 否 | 是 |
| `remotePreview(at)` | 更新预检：远端有哪些变更 | 是 | 否 | 否 | 是 |
| `list(url,revision)` | 浏览仓库目录 | 是 | 否 | 否 | 是 |
| `makeDirectory(url,message)` | 远程建目录（一次提交） | 是 | 否 | 否 | 否 |
| `copy(from,to,message,parents)` | 远程复制 / 建 tag | 是 | 否 | 否 | 否 |
| `moveRemote(from,to,message)` | 远程移动 | 是 | 否 | 否 | 否 |
| `deleteRemote(url,message,confirmed)` | 远程删除 | 是 | 否 | **是** | 否 |
| `remoteProperties(url)` | 远程属性（只读） | 是 | 否 | 否 | 是 |
| `export(from,to,revision)` | 导出快照（无 .svn） | 是 | 否 | 否 | 否 |
| `importDirectory(from,to,message)` | 导入本地目录 | 是 | 否 | 否 | 否 |
| `relocate(wc,to)` | 切换仓库地址 | 否 | 是 | 否 | 否 |
| `setChangelist(name,paths)` | 本地变更集 | 否 | 是 | 否 | 是 |
| `previewMerge(request)` | 描述合并后果（纯计算） | 否 | 否 | — | 是 |
| `merge(request,confirmed)` | 自动合并 / 两 URL 合并 / record-only | 是 | 是 | **是** | 否 |
| `mergeInfo(kind,source,target)` | 已合并 / 可合并修订 | 是 | 否 | 否 | 是 |
| `mergeInfoProperty(at)` | 读取 `svn:mergeinfo` 原始值 | 否† | 否 | 否 | 是 |
| `previewSwitch(request)` | 描述切换后果（纯计算） | 否 | 否 | — | 是 |
| `switchTo(request,confirmed)` | 切换到同仓库另一 URL | 是 | 是 | **是** | 否 |
| `createLocalRepository(at)` | `svnadmin create` 本地仓库 | 否 | 否 | 否 | 否 |

\* `info` 针对工作副本路径时只读本地 `.svn`；针对 URL 时访问网络。
† `mergeInfoProperty`（`propget`）对仓库 URL 目标会访问网络；对工作副本路径只读本地 `.svn`。

### 1.1 checkout

- 前置：目标不存在，或存在且为空目录。否则返回 `SVN-9001`。
- 副作用：创建完整工作副本；失败可能留下部分目录，**不得**自动删除用户目录。
- 深度：`infinity` / `immediates` / `files` / `empty`。
- 序列化键：目标绝对路径。

### 1.2 update

- 前置：目标在工作副本内。
- **没有 dry run**。`svn update` 一旦运行就会改文件，因此"更新前看看会拉下什么"必须由 `remotePreview` 提供，而不是给 `update` 加参数。
- 成功判据：退出码 0；新修订号通过随后一次 `svn info --xml` 读取，而不是解析 “Updated to” 文本。
- 摘要：从输出行提取 `A/D/U/C/G` 首列，仅用于展示。
- 冲突：`update` 不解决冲突，只报告。冲突详情以 `status --xml` 为准。
- 中断：可能留下混合修订版本与内部锁，用户需执行 `cleanup`。这是 `cleanup` 存在的主要理由。

### 1.3 status

- `--xml`；`includeIgnored: false` 时不加 `--no-ignore`。
- 返回的路径可能是绝对路径（传入绝对路径时）或相对路径（传入相对目标时），调用方不得假设。
- 默认不访问网络。`checkRepository: true` 时加 `--show-updates`（即 `-u`），此时**会**联网，并额外得到两样东西：`<repos-status>`（远端变更与他人持有的锁）和 `<against revision="N">`（服务器最新修订号）。

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

### 1.7b 三方合并（先合并，后 resolve）

文本冲突可以逐块决定，而不是只能整份取舍。契约：

1. **三个版本从 `svn info --xml` 读，不从文件名猜**。`<conflict>` 给出 `prev-base-file`（基线）
   与 `prev-wc-file`（我的），对方版本由 `<version side="source-right" revision="N">` 推出
   `.r<N>`。同一个文件被多次更新后会留下多个 `.r*`，"取最新那个"会取错。
2. **一次改动一侧的区域自动采用**，只把两侧都改且不同的区域交给用户。把单边改动也变成选择题，
   是在用噪音掩盖真正需要判断的地方。
3. **未决定的区域不得写入**：渲染器在有未决定项时抛错，不生成带标记的半成品文件。
4. **先备份，再写文件，最后 `resolve --accept=working`**。顺序不可交换：`resolve` 自己也会备份，
   但那时工作文件已经是合并结果，原始冲突内容只能靠第 4 步之前的备份保住。
   `working` 的语义正好是"以磁盘内容为准"，因此 resolve 不会覆盖刚写入的结果。
5. 只有 `type="text"` 的冲突提供该入口；属性冲突与树冲突没有可三方比较的基线。

### 1.8 cleanup

- 无网络，幂等。
- 不删除用户文件；“清理”仅指 `.svn` 内部锁与未完成事务。
- 若 `cleanup` 后仍报 `E155004`，错误映射必须提示“工作副本可能损坏，请备份后重新检出”，而不是反复重试。

### 1.9 属性（properties / setProperty / deleteProperty / ignore）

属性是版本化元数据，和文件内容一起提交。

| 项 | 契约 |
|---|---|
| 读取 | `proplist --xml --verbose [--recursive]`。**不能用 `propget`**：它必须带一个属性名，问的是另一个问题 |
| 无属性 | `svn` 输出空的 `<properties>`（没有 `<target>`），解析结果为 0 个目标，不是错误 |
| 写入值 | 值经**临时文件 + `-F`** 传入，不作为 argv：以 `-` 开头的值会被当成选项，多行值（`svn:ignore`）是常态 |
| 参数边界 | 属性名之后加 `--`，再列路径。路径本身以 `-` 开头时仍然安全 |
| 确认 | **不需要 `confirmed`**。这是本地可还原的修改（`revert` 可撤销），提交前不影响仓库；删除路径/覆盖式解决冲突才算危险操作 |
| 串行 | 仍走 R4 写锁：两个 `propset` 会争用同一个 `.svn/wc.db` |
| 尾换行 | `svn` 会把 `svn:ignore` 规范化成以换行结尾。**比较必须按条目**，不能比原始字符串 |
| 名称校验 | 只允许 `[A-Za-z0-9:._-]`；自定义属性必须带命名空间（`custom:owner`）；`svn:entry:` / `svn:wc:` 前缀拒绝写入。校验在启动子进程**之前**完成 |
| `ignore(paths)` | 读该目录现有 `svn:ignore`，追加文件名后一次写回；已存在则**不写**（无意义写入也会让目录变成属性已修改，混进下次提交） |
| 通配符转义 | `svn:ignore` 是 glob 列表。文件名里的 `*` `?` `[` `]` 必须转义为 `[*]` `[?]` `[[]` `[]]`，否则 `report*.txt` 会忽略掉一整类文件 |
| 删除 | 只对确实拥有该属性的路径执行 `propdel`；全部不存在时返回 0，不报错 |

### 1.10 锁定（lock / unlock / locks）

SVN 里有两套完全不同的"锁"，从错误码到补救动作都不一样，**不得合并成一个概念**：

| 名称 | 来源 | 报错 | 解法 |
|---|---|---|---|
| 工作副本内部锁 | 上次操作中断留下的 `.svn` 事务锁 | `E155004`（`SVN-0004`） | `svn cleanup` |
| 仓库锁 | `svn lock` 在服务器上登记的独占编辑权 | `W160035`（`SVN-0304`） | 由持有人 `unlock`，或有意识地 `--force` 抢占 |

| 项 | 契约 |
|---|---|
| 读取 | `svn status --xml --show-updates`。**只有 `-u` 能看到别人持有的锁**；不带 `-u` 时 svn 只报告本工作副本持有的 token |
| 两处 `<lock>` | `<wc-status>` 里的锁 = 本工作副本持有（有 token）；`<repos-status>` 里的锁 = 服务器现状，可能是别人的。模型分别记为 `repositoryLock` / `remoteLock`，界面据此决定给"解除"还是"抢占" |
| 网络 | `locks(at)` 会访问服务器，因此**不并入 `refresh()`**：本地状态刷新绝不能因为服务器不可达而卡住 |
| lock | `svn lock [-m 说明] [--force] -- <paths>`。普通锁定可撤销、不改变文件内容，因此**不需要 `confirmed`** |
| steal | `--force` 抢占他人锁，服务层要求 `confirmed: true`（R3），界面拦截只是第二道防线 |
| unlock | `svn unlock [--force] -- <paths>`；`--force` 解除他人锁，同样要求 `confirmed` |
| 输出 | `svn lock` 没有 `--xml`。成功时读 stdout（`'<path>' locked by user '<owner>'.` / `'<path>' unlocked.`）；**解析失败不得让已成功的操作失败**——退出码是契约，文案只是顺带 |
| 失败映射 | `W160035`（已被他人锁定）→ `SVN-0304`；`W160040` / `E195013`（无锁）→ `SVN-0305`。**不能映射到 `E200009`**：那只是"有一个锁操作失败"的汇总，说不清原因 |
| 串行 | lock / unlock 会写 `.svn/wc.db`（记录 token），因此走 R4 写锁，并记 journal（`.lock` / `.unlock`） |
| 提交后 | `svn commit` 默认释放该路径的锁（除非 `--keep-locks`），所以界面不需要"提交后自动解锁"选项 |
| 只读操作 | `locks(at)` 不加锁、不记 journal（与 `status` 同类） |

### 1.11 更新预检（remotePreview）

`svn update` 没有 dry run，所以在执行之前，唯一能回答"会拉下什么"的命令是 `status --show-updates`。本方法就是它的读取端。

| 项 | 契约 |
|---|---|
| 命令 | `svn status --xml --show-updates -- <path>`，与 `locks(at)` 完全相同的命令，不同的读法 |
| 只读 | 不写工作副本、不记 journal、不取写锁。读取前后工作副本状态必须一致（集成测试断言这一点） |
| `nil` 的含义 | `<repos-status>` 只在该路径与基准修订不同时出现。因此 `remoteItem == nil` 表示"服务器上没变"，**不是**"未知"。把两者混为一谈会让预览把整个工作副本列成待更新 |
| 修订号 | `<against revision="N"/>` 是服务器当前的最新修订号，也就是 `update` 会落到的地方。没有 `revision` 属性时保持 `nil`，不能当作 0 |
| 根条目 | svn 会为工作副本根 `"."` 报一条 `modified`，只要任意子项变了。**必须过滤掉**，否则 3 个文件的变化会显示成 4 条。唯一的例外是根目录自身的属性变更（`item` 为 `none`/`normal` 而 `props` 为 `modified`），它保留为单独一行 |
| 目录去重 | 目录会因某个子项变化而被报为 `modified`。当它同时(1) 有变化的后代、(2) 自身属性未变时，从列表中移除——一条变化不该被计两次 |
| 冲突风险 | **启发式，不是判定**。远端 `modified`/`deleted` 与本地 `modified`/`added`/`deleted`/`conflicted`/`missing` 在同一路径上相遇时标记为"可能冲突"；远端 `added` 遇到本地 `unversioned` 同理（会 `obstructed`）。是否真冲突取决于内容，只有 `update` 之后才知道，所以界面文案必须写"可能" |
| 网络失败 | 预检失败**不阻止**更新。界面在失败态里保留"仍然更新"按钮：`--show-updates` 失败可能只是这台服务器不支持或代理拦了，而 `update` 未必同样失败 |
| 与 `locks(at)` 的关系 | 两者共用 `status -u`，但不合并入口：一个问归属，一个问内容。合并会迫使锁刷新解析它从不显示的数据 |

### 1.12 历史、搜索与注解

| 项 | 契约 |
|---|---|
| 缓存键 | 工作副本根路径 + 相对目标 + 仓库 UUID。目标不同（整个工作副本 vs 单个文件）各存一份，互不驱逐 |
| 仓库 UUID 不匹配 | 丢弃缓存。`dump`/`load` 重建的仓库路径不变而修订号含义全变，复用会显示从未存在过的历史 |
| 增量拉取 | `-r HEAD:<已缓存最新>`，**包含**该修订。它作为最后一行返回并被去重丢弃——这同时证明缓存与服务器说的是同一个修订，而不是假设它们一致。`HEAD:<最新+1>` 在无新提交时会指向不存在的修订 |
| `-l` 与 `--search` | 不能叠加成直觉的效果。带 `--search` 时 `-l` 限制的是**扫描**条数而非输出条数，要 50 条匹配会先扫 50 个修订再返回空。因此搜索不传 `-l`，代价是全历史扫描，必须作为可取消的任务运行 |
| `--search` 的目标 | **必须是仓库 URL**。实测 svn 1.14.5：同一模式对工作副本路径恒返回空日志，对仓库 URL 才能命中。路径要先翻译成 URL |
| `--search` 的粒度 | 匹配 author / date / message / changed paths 中的任意一个，无法限定字段。按字段的精确筛选只能在客户端对已加载条目做，两者并列提供给用户 |
| 搜索结果 | 不写缓存。它是过滤视图，不是历史本身；写进去会让下次打开看到一份残缺的历史 |
| 单文件历史 | `svn log <path>` **默认跟随 copy 历史**（`--stop-on-copy` 才是关闭）。改名后的文件自动带上改名前的修订，不需要额外参数——集成测试用真实 rename 验证这一点 |
| blame 的对象 | 对工作副本路径注解的是**磁盘上的文件**，本地未提交的行没有 revision（CLI 显示 `-`）。这恰好是提交前想看的东西：未提交的改动不会被算到别人头上 |
| blame 的文本 | `--xml` 只给行号/修订/作者/日期，不含内容。内容从同一个文件读，二者行数一致；行数多出时留空而不是错位，错位会把内容归给错误的修订 |
| 只读 | 三者都不写工作副本、不记 journal、不需要确认 |

### 1.13 仓库侧操作（URL 目标）

svn 自己就把「工作副本路径」和「URL」分成两套语义：`svn mkdir path` 暂存一个改动等着 commit，`svn mkdir URL` 当场提交。两者混在一个方法后面，会让人分不清刚才做的是哪一种，所以本文把 URL 目标单列一节。

| 项 | 契约 |
|---|---|
| 提交语义 | `mkdir` / `copy` / `move` / `delete` 针对 URL 时**各自产生一次提交**，没有暂存阶段，因此没有"确认后撤销"的余地。方法名以 `Remote` 结尾或带 `url` 参数，是为了在调用处就能看出这一点 |
| 提交说明 | 必填，服务层校验。svn 要求 `-m`，空说明会进入历史且无法事后区分"没写"和"写错了" |
| 修订号 | 从 stdout 的 `Committed revision N.` 提取，**可以为 nil**。退出码是契约，文案只是顺带；解析失败不得把成功的操作变成失败 |
| 删除 | 服务层要求 `confirmed`（R3）。svn 保留历史所以可恢复，但恢复需要知道修订号并执行命令，那不是点确认的人能做到的 |
| `--parents` | `copy` 与 `mkdir` 支持。建 tag 时 `tags/` 往往还不存在，没有它就得让用户先手动建一层 |
| tag / branch | **不是独立命令**，是目录 `copy` 的约定。UI 提供"创建 tag"只是替用户写好 `tags/<name>` 这个目的地，不会改变 svn 的历史模型 |
| 远程属性 | **只读**。svn 1.14 对 URL 执行 `svn propset` 直接报 `E200009: Targets must be working copy paths`，不存在远程改属性的能力。改属性需要检出，因此界面必须说清这一点，而不是给一个注定失败的输入框 |
| 属性读取 | `svn proplist --xml --recursive --verbose URL`。`--xml` 必须带，否则输出格式不同（不带 `--xml` 的 `-R -v` 在实际测试里返回空） |
| export | `svn export [-r N] URL DEST`，产出没有 `.svn` 的树。目标目录必须为空，svn 不覆盖 |
| import | `svn import PATH URL -m`，一次提交整棵树。目标不能已存在 |
| relocate | `svn relocate NEW_URL`，在工作副本目录内执行。UUID 检查是 svn 的：relocate 到另一个仓库会失败，这是"不会把两段历史接错"的保证 |
| changelist | 纯本地概念，从不进入服务器。`svn changelist NAME paths` / `--remove`；它只影响 `status` 的分组和 `commit --changelist` 的选择 |

**`svn status --xml` 里 changelist 的位置（实测）**

changelist 成员不在 `<target>` 下，也不是 entry 的属性，而是 `<target>` 的**兄弟元素**：

```xml
<status>
  <target path="trunk"><entry path="trunk/sub/b.txt">…</entry></target>
  <changelist name="ui-review"><entry path="trunk/readme.md">…</entry></changelist>
</status>
```

只遍历 `<target>` 的解析器会**静默丢掉**所有被设进 changelist 的文件——没有报错，文件从列表里消失。这是文件列表最坏的失败方式，因此解析必须同时读两处。

### 1.14 externals 与提交边界

`svn:externals` 挂载的是**另一个工作副本**，可能来自另一个仓库。svn 在 status 里只给挂载点本身 `item="external"` 标记，其内部的改动与父工作副本的改动用同样的 `modified` 出现在同一份输出里。

| 项 | 契约 |
|---|---|
| 分类 | `external` 是独立分类，**不得**归入 `ignored`。ignored 是"不关心的噪音"，external 是"别人的工作副本" |
| 提交边界 | 挂载点及其下的所有路径都不可从本工作副本提交。`StatusSnapshot.committable` 负责排除，UI 的计数与勾选都基于它 |
| 判定 | 祖先目录是 external 才算"在外部之内"。路径前缀必须带分隔符比较，否则 `/wc/shared-notes.md` 会被当成 `/wc/shared` 的子路径 |
| 只读展示 | `svn propget svn:externals -R URL` 可读；修改同 §1.13——没有远程 propset |

## 2. 中断恢复（操作日志）

写操作（checkout / update / commit / add / delete / revert / resolve / cleanup / property / lock / unlock）在**启动子进程之前**落一条记录，在子进程返回后删除。启动时仍然存在的记录，按定义就是"上次没有结果的操作"。

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

## 5. 能力状态与补充契约

### 5.0 状态校正（与代码对齐）

旧版本节写作「未实现的接口（后续版本）：`switch`、`merge`、`export`」。该描述已与代码不符：

| 接口 | 状态 | 实现位置 |
|---|---|---|
| `export` | **已实现**（2026-10-25） | `SVNService.export(from:to:revision:)`，见 §1 方法表与 §1.13 |
| `merge` | **已实现**（本次） | `SVNService.previewMerge` / `merge`，见 §5.1 |
| `switch` | **已实现**（本次） | `SVNService.previewSwitch` / `switchTo`，见 §5.2 |

本节其余条目是本次新增能力的**行为契约**，不是实现说明；两端（macOS / 其他平台）的语义、前置条件、副作用、失败后状态必须一致。契约先于或同步于实现，不是先写完代码再补文档。

**写锁与中断日志的复用约定**：`OperationJournal.Entry.Kind` 是带穷尽 `recoveryAdvice` 的封闭枚举。本次新增的写操作不新增 `Kind`，而是复用现有枚举——`merge` / `switch` 记为 `.update`（"工作副本可能停在中间状态，运行清理"），`createLocalRepository` 记为 `.checkout`（"可能只完成了一部分，确认目录内容后再决定"）。这两种恢复建议恰好就是对应操作被中断后的真实状态，因此是语义契合而非权宜。三者一律走 R4 写锁 + `beginJournal` / `finishJournal`；危险操作一律由服务层拒绝未 `confirmed` 调用（R3）。

### 5.1 merge（分支合并 / merge tracking）

| 项 | 契约 |
|---|---|
| 语义 | 封装 `svn merge`（svn 1.14 语义）。两种形式：`automatic`（`svn merge [-r N:M \| -c N] SOURCE[@PEG] [TARGET]`，即由 `svn:mergeinfo` 驱动的自动/sync/reintegrate 合并）与 `twoURL`（`svn merge SOURCE1[@N] SOURCE2[@M] [TARGET]`）。支持 `--record-only`（只更新合并记录、不应用改动）、`--accept`、`--ignore-ancestry`、修订范围/挑拣 |
| 入参 | `MergeRequest(style, target, recordOnly=false, accept=.postpone, ignoreAncestry=false)`；另有 `confirmed: Bool`、`credential`、`progress`。`previewMerge(request) -> OperationPreview` 为纯计算预览 |
| 前置条件 | 目标为工作副本路径；来源 URL 非空（`validate()` 在启动子进程前校验，空则 `SVN-9001`）；`confirmed == true`；凭据按 §4 流程解析，密码只走 stdin |
| 副作用 | 仅改工作副本（文件内容、`svn:mergeinfo`、可能留下冲突标记）；**不提交**，`--record-only` 只改属性。走写锁 + `.update` journal；记 debug 日志 |
| 幂等性 | 否。重复合并会产生重复改动或冲突（svn 自身也不保证合并幂等）；`--record-only` 重复执行仍需谨慎，应以 mergeinfo 为准 |
| 失败后工作副本状态 | 可能处于混合修订 / 含未解决冲突 / 中间状态，且可能已写入部分改动。返回 `SVN-0501`（未确认）、`SVN-9001`（入参非法）、冲突相关或 svn 映射错误；失败即 `finishJournal` 删除日志条目。恢复建议：刷新状态、必要时 `cleanup`、按需 `revert` 后重试，不要盲目重复合并 |
| 确认策略 | **服务层强制**：`confirmed == false` 抛 `SVN-0501 confirmationRequired`，附带 `OperationPreview` 摘要/详情，且不启动任何子进程。`previewMerge` 是只读纯计算，不扫描工作副本；本地改动由调用方另外用 `status` / `remotePreview` 检查 |

### 5.2 switch（切换到同仓库另一 URL）

| 项 | 契约 |
|---|---|
| 语义 | 封装 `svn switch URL[@PEG] [PATH]`：把工作副本整体指向**同一仓库内**的另一个 URL（分支）。不是 `relocate`（同仓库换地址），也不是拼接两段历史——仓库 UUID 由 svn 校验，切到别的仓库会失败 |
| 入参 | `SwitchRequest(url, target, revision=nil, accept=.postpone, ignoreExternals=false, force=false)`；另有 `confirmed: Bool`、`credential`、`progress`。`previewSwitch(request) -> OperationPreview` 为纯计算预览 |
| 前置条件 | 目标 URL 非空（`validate()` → 空则 `SVN-9001`）；`confirmed == true`；UUID 一致性由 svn 保证 |
| 副作用 | 更新工作副本内容、`.svn/wc.db` 中的 URL；`--force` 可能覆盖未版本化的同名文件；`--ignore-externals` 保留外挂不动。走写锁 + `.update` journal |
| 幂等性 | 否（切换会重写文件；已处于目标 URL 时 svn 视为无操作，但服务层不做此判定） |
| 失败后工作副本状态 | 可能停在混合修订或残留冲突，需刷新状态并视情况 `cleanup`；失败即 `finishJournal` |
| 确认策略 | **服务层强制**：`confirmed == false` 抛 `SVN-0501`，不启动任何子进程。`previewSwitch` 为只读纯计算 |

### 5.3 mergeinfo 读取

| 项 | 契约 |
|---|---|
| 语义 | 两种互补的只读入口：`mergeInfo(kind, source, target)` 跑 `svn mergeinfo --show-revs <merged\|eligible>` 返回已合并/可合并修订号列表；`mergeInfoProperty(at)` 跑 `svn propget svn:mergeinfo` 返回解析后的 `path:rangelist` 行（含范围与非继承 `*` 标记） |
| 入参 | `MergeInfoRevisions.merged / .eligible`、`source: String`（URL 或路径）、可选 `target: URL`；`mergeInfoProperty` 接受路径或 URL 字符串；均带可选 `credential` |
| 前置条件 | 无确认、无写锁；`--show-revs` 面向仓库需网络，`propget` 对 URL 目标需网络 |
| 副作用 | 无。不改工作副本、不记 journal、不取写锁 |
| 幂等性 | 是（纯读） |
| 失败后工作副本状态 | 不变；错误按 `SVNErrorMapper` 映射或读失败上抛 |
| 确认策略 | 不需要 `confirmed` |

### 5.4 创建本地仓库（svnadmin create）

| 项 | 契约 |
|---|---|
| 语义 | 封装 `svnadmin create PATH`，创建全新的本地空仓库；返回 `LocalRepository`（仓库路径 + `file://` URL，经 `URL(fileURLWithPath:)` 正确百分号编码，含空格/中文路径） |
| 入参 | `createLocalRepository(at location: URL)` |
| 前置条件 | 目标不存在，或存在且为空目录；目标已存在且非空 / 是文件时返回 `SVN-9001`，**不覆盖用户已有内容**。`svnadmin` 与 `svn` 同目录（参考 `DemoWorkspace.adminTool(nextTo:)`），找不到返回 `SVN-0001` |
| 副作用 | 在磁盘创建仓库目录树（自动补建父目录）。`svnadmin` 是**不同于 `svn` 的二进制**，不接受 `--non-interactive` / `--no-auth-cache`，因此走独立的 `SVNProcessRunner`（不自建 `Process`），不经 `invoke` 的全局参数。仍走写锁 + `.checkout` journal |
| 幂等性 | 否：目标非空即拒绝，因此不会重复创建；但不静默吞掉"已存在" |
| 失败后工作副本状态 | 不接触任何现有工作副本；可能留下一个不完整的仓库目录，由用户按恢复建议删除重建。失败即 `finishJournal` |
| 确认策略 | 不需要 `confirmed`：只新建、不删除、不覆盖（非空即拒绝），是非破坏性本地操作 |

### 5.5 checkout：Pristines on Demand

| 项 | 契约 |
|---|---|
| 语义 | `checkout` 新增可选参数 `storePristines: Bool = true`。默认 `true` = 保持原有行为（svn 默认存储 pristine 副本）；`false` 追加 `--store-pristine=no`（svn 1.15 "Pristines on Demand"，按需从仓库取 pristine，不本地保存） |
| 入参 | `checkout(url,to,revision,depth,storePristines=true,credential,progress)`；参数带标签，新增项不改变既有调用语义 |
| 前置条件 | 同 §1.1：目标不存在或为空目录。另需 svn ≥ 1.15：低于该版本时服务层在**启动子进程之前**直接拒绝（`SVN-9001`），不依赖 svn 报错 |
| 副作用 | 创建工作副本；`storePristines=false` 时 `.svn/pristine/` 不保存完整副本，**且工作副本格式升级为 32**——svn 1.14 及更旧客户端因此无法打开该工作副本。这是拒绝低版本的全部理由，不只是"选项不存在"。走写锁 + `.checkout` journal（既有行为） |
| 幂等性 | 目标非空时拒绝；其余同 §1.1 |
| 失败后工作副本状态 | 可能留下部分目录，不自动删除用户目录（同 §1.1） |
| 确认策略 | 不需要 `confirmed`（既有 checkout 语义不变） |

**选项拼写（实测 svn 1.15）**：真实选项是单数 `--store-pristine`，取值 `yes`/`no`，且必须以 `--store-pristine=no` 形式传入（单个 argv 元素）。复数 `--store-pristines=no` 会被 svn 判为 `svn: invalid option` 而拒绝；早期设计草稿里的复数写法不生效，实现与本文一律采用单数形式。该选项在 1.15 之前不存在（1.14 及更旧版本的 `svn help checkout` 中没有它），因此不是"旧版本会报错"，而是旧版本根本没有这个能力。

### 5.6 跨仓库分别提交（书面结论，不实现）

**结论：本节刻意不提供实现，只给出结论与理由。** 用户诉求是"按待提交路径解析所属仓库 URL/UUID 分组，一次 commit 只发同一仓库的路径"。理想做法是对每个路径 `svn info --xml` 取 `<repository><root>` 与 `<uuid>`，按 `(root, uuid)` 分组，每组各发一次 `svn commit`。但当前服务层**不会**加这套自动分组，原因如下：

1. **svn 自身的提交边界就是单一仓库。** `svn commit` 一次调用针对的是同一个仓库的工作副本；把来自不同仓库的路径混在一次调用里，svn 会拒绝（"are not from the same repository" 一类错误）。因此"一次 commit 只发同一仓库的路径"本来就是 `commit` 的既有约束，不需要（也不应该）在服务层再造一层分组。
2. **externals 是被明确排除的提交边界。** `svn:externals` 挂载的是**另一个工作副本**，可能来自**另一个仓库**。svn 明确拒绝把外挂挂载点内部的改动随父工作副本一起提交：自 svn 1.7 起 `svn commit` 默认不深入 external，外挂内的改动必须在其自身工作副本内单独提交。见 §1.14：`StatusSnapshot.committable` 已负责把挂载点及祖先为 external 的路径排除在可提交集合之外（判定用带分隔符的前缀比较，`/wc/shared-notes.md` 不会被误判为 `/wc/shared` 的子路径）。
3. **"按 UUID 分组后自动分别提交"是危险且误导的假实现。** 若服务层偷偷把外挂/别的仓库的路径也纳入分组并各发一次提交，等于在一次用户动作里静默提交了用户并未明确选择的、可能属于他人/他仓库的内容，违背 §1.14 的提交边界契约，也违背"预览—确认—提交"的可见性原则。分组本身还依赖 `svn info` 的网络往返与缓存一致性（§1.12 已说明 UUID 不匹配时缓存必须丢弃），把它做进提交路径只会增加不可预测的副作用。

**因此采用的行为**：`commit` 保持"一次调用、单一仓库、路径来自同一工作副本"；调用方（UI）用 `StatusSnapshot.committable` 过滤掉 external 路径后再提交；若用户确实要提交某个 external 或另一个仓库，应打开那个工作副本、由用户显式发起一次独立的提交。这把"跨仓库分别提交"表达为**多次显式的用户动作**，而不是服务层一次隐式分组。此结论为书面约定，不产生任何新的分组/多提交代码。
