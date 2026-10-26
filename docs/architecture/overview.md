# 架构概览（macOS）

```text
SwiftUI Views
   │  (只读状态 + 触发动作)
   ▼
AppState / RepositorySession                   @MainActor, Observation
   │  (无 shell 拼接、无凭据持久化)
   ▼
TaskCenter (core)                              任务、取消、失败重试
   │
   ▼
SVNService (actor)                             ← 唯一 svn 入口
   ├── WCWriteGate     写串行化 + 全局并发上限
   ├── CredentialStore Keychain / InMemory
   ├── SVNProcessRunner 参数数组 / 双管道 / 取消 / 超时
   ├── SVNXMLParser     status / log / info
   ├── AppLog           脱敏日志（默认关闭）
   └── SVNDiscovery     内置 → 显式 → PATH → 常见位置
   │
   ▼
svn CLI (child process)
```

`TaskCenter` sits in the core rather than the app target so retry semantics can
be tested without a window; it is `@MainActor` and has no SwiftUI dependency.

## 分层职责

| 层 | 位置 | 负责 | 不负责 |
|---|---|---|---|
| 模型 | `Sources/OpenSVNCore/Models` | 状态、冲突、锁、日志、错误、进度 | 任何 I/O |
| 进程 | `Process/SVNProcessRunner.swift` | 启动、管道、取消、超时、环境白名单、SIGPIPE | 业务语义 |
| 解析 | `Parsing/` | XML → 模型 | 判断操作是否成功 |
| 发现 | `Discovery/` | 找 svn、校验版本 | 安装 svn |
| 服务 | `Services/SVNService.swift` | 命令编排、凭据、错误分类、串行化 | UI 状态 |
| 界面 | `Sources/OpenSVN` | 状态展示、确认交互、任务中心 | 直接调用 `Process` |

## 关键约束（以及为什么）

1. **视图不碰 `SVNService` 之外的层**。视图里出现 `Process` 或 `svn` 字符串即为设计违规。
2. **`SVNService` 是 actor**：所有 svn 调用天然串行进入，但 `await` 期间可重入，因此读操作不会被写操作永久阻塞；写操作的互斥由 `WCWriteGate` 单独保证（actor 本身不保证跨调用互斥）。
3. **`TaskCenter` 是唯一的取消与重试入口**：界面不持有 `Task`，取消通过任务条目进行，避免"视图销毁导致任务泄漏"；失败条目保留执行闭包，重试即重跑同一请求，成功后闭包被释放。
4. **`RepositorySession` 不引用 `AppState`**：通过 `onCredentialRequired` 闭包反向请求凭据，避免双向持有。
5. **进度回调是结构体而非闭包**：`SVNProgressReporter` 可自由跨层传递，避免 `@escaping` 污染整条调用链。
6. **日志不参与控制流**：`AppLog` 的每个失败路径都被吞掉，写不了日志不能变成操作失败；共享实例默认 `.off`，只有 `AppState.start()` 按用户设置打开。

## 数据流（一次提交）

1. `CommitView` 调 `RepositorySession.commit()`。
2. Session 校验说明非空、勾选非空。
3. `TaskCenter.run` 创建任务条目，进入 `SVNService.commit`。
4. Service 取得写锁 → 对每个路径重新 `status`（发现冲突即中止）→ 启动 `svn commit`。
5. Runner 并发读 stdout/stderr，逐行回调进度；任务中心更新详情。
6. 成功 → Service 返回 `CommitSummary`；Session 清空说明、刷新状态、重载历史。
7. 失败 → `SVNErrorMapper` 分类 → Session 呈现错误；任务条目保留。

## 中断恢复（S5-4）

写操作在启动子进程前记录到 `OperationJournal`，返回后删除。启动时仍然存在的记录，按定义就是"上次没有结果的操作"。

三条实现约束：

1. **写入必须在 spawn 之前。** 反过来的话，进程在最危险的窗口（子进程已开始改工作副本）里没有任何痕迹。
2. **失败也删记录。** `svn` 退出非零是已知结果，不是中断；把它当作残留会让每次普通错误都弹恢复提示，用户很快学会无视它。
3. **磁盘是唯一事实来源。** `unfinished()` 每次都重新读文件，不缓存。缓存会在"另一个实例刚写完"时给出过期答案——这个缺陷在单元测试第一次运行时就暴露了，比在生产里暴露便宜得多。

界面是窗口顶部的一条横幅，不是 alert：恢复提示可能与用户此刻想做的事无关，alert 会打断操作并训练用户盲点关闭。`commit` 的建议文案是"先刷新确认"，绝不是"重试"。

## 故障注入（S5-5）

`tests/scenarios/failure/` 用真实进程验证"世界不听话时产品是否还对"，与 `apps/macos/Tests/` 的分工是：
单元测试证明**映射表读对了字符串**，场景证明**真实 svn 在真实故障下真的长那样**。五个场景（F8/F9/F10/F11/F12）已进 CI。

两个让它可靠的机关：

1. **按字节截断的 TCP 代理**（`support/tcp_proxy.py`）。"睡 200ms 后杀服务器"是赛跑：机器快则传输已结束，慢则还没开始，同一份脚本在 CI 上时红时绿。改成"服务器→客户端方向数够 N 字节就 RST"之后，中断位置变成确定的。代理只计量该方向，握手因此总能完成。
2. **`opensvn-probe`**。契约的一半是"用户被告知什么"，而这句话在 Swift 里（`SVNErrorMapper`）。这个只用于开发的命令把真实 stderr 过一遍映射表并打印稳定标识，场景脚本因此能断言 `SVN-0006` 而不是只能断言 svn 自己的 `E` 码。它不打进 `.app`。

这套 harness 立刻证明了它的价值：三个场景在第一次运行就红了，红的都不是脚本，而是产品——
只读磁盘被讲成"请执行 Cleanup"（Cleanup 要写同一块只读盘）、新格式仓库被讲成"检查网络"、
传输中断被讲成"请提 issue"。根因是同一个：**映射表按 token 在表内的顺序命中，而 svn 把症状打在原因前面**。

## Windows 端（尚未开始）

`apps/windows/` 现在只有一个占位文件。2026-10-18 之前这里有一套 WinUI 3 + C++20
骨架，但它在 CI 上第一次真机编译就暴露出三个连锁问题：

1. `OpenSVNTests.vcxproj` 漏了 `/std:c++20`，MSVC 退回 C++14，`std::string_view`
   与 `std::optional` 全部报错；
2. GoogleTest 没有由 vcpkg 安装，`gtest/gtest.h` 找不到；
3. WinUI 工程 restore 成功却报 `does not reference "UAP,Version=v10.0"`——把 WinUI 3
   和 UWP 的目标框架混在了一起。

这三条互相掩盖，且没有任何一条能在 macOS 上验证。与其留一份"看起来有实现"的目录，
不如整体删掉，重做时从零开始。`windows-ci.yml` 与 `bootstrap-windows.ps1` 也已删除；
**代码、CI、引导脚本必须在同一次提交里出现**。

共享的是 `specifications/` 的行为契约，不是代码。重做时值得先读的三条差异：

1. **参数传递**：Win32 只接受一整条命令行字符串。R1 在这里的含义是"由参数数组**拼**出命令行并逐项加引号"，绝不经过 `cmd.exe`。
2. **取消**：macOS 用 SIGTERM → SIGKILL；Windows 必须用 Job Object + `TerminateJobObject`，否则 `svn` 的子进程会变成孤儿并占住工作副本锁。
3. **路径编码**：`path.string()` 会走当前代码页并毁掉中文路径，必须走 `u8string()`；同时 `app.manifest` 需声明 UTF-8 活动代码页与 `longPathAware`。

## 目录映射（ADR-0007 记录的原定结构 ↔ 实际）

原定结构假定 macOS 是纯 Xcode 工程；实际以 SwiftPM 为主，原因见 ADR-0007。对照关系：

| 原定结构 | 实际 | 说明 |
|---|---|---|
| `apps/macos/OpenSVN/Services/` | `apps/macos/Sources/OpenSVNCore/{Process,Parsing,Discovery,Services,Support}/` | 核心层拆成可独立测试的 target |
| `apps/macos/OpenSVN/Models/` | `apps/macos/Sources/OpenSVNCore/Models/` | 同上 |
| `apps/macos/OpenSVN/{App,Views,ViewModels}/` | `apps/macos/Sources/OpenSVN/{App,Views,ViewModels,Models}/` | 界面层 |
| `apps/macos/OpenSVNTests/` | `apps/macos/Tests/OpenSVNCoreTests/` | Swift Testing |
| `apps/macos/OpenSVNUITests/` | 暂无 | 界面测试要等打包稳定（阶段 6） |
| `apps/windows/**` | 暂无（2026-10-18 清空） | 重做时按 ADR-0007 记录的原定布局；不要为了对齐目录而提前建空壳 |
| `assets/{branding,icons,screenshots}` | 不入库（`.gitignore` 里 `/assets/`，本地保留） | 三个目录里各只有一个占位 README，等于向读者承诺并不存在的美术资源。阶段 6 真做出图标与截图时再放回来 |

`python3 scripts/verify-release.py --layout` 会逐项检查这张表对应的目录与锚点文件是否**被 git 跟踪**。只检查"存在"还不够：文件被挪进被忽略的目录、或还没 `git add` 时，本地看着齐全，CI 的干净 checkout 里却没有它——2026-10-22 那次红灯就是这么来的。同理，`internal/` 下任何被跟踪的文件都会直接判失败。

## 冲突解决：先合并，后 resolve（S5-2）

文本冲突的完整链路是"算出区域 → 用户逐块决定 → 写文件 → `resolve --accept=working`"。
四个决定值得写下来：

1. **合并是纯函数**（`ThreeWayMerge`），界面只保存"每一块选了哪边"。这样"哪些区域冲突、
   两边各写了什么"可以脱离窗口测试——14 个用例覆盖了单边改动、删除对编辑、末尾追加、
   空基线、换行符保留。
2. **只在两侧都改且不同时才提问**。单边改动自动采用，否则一个 200 行的合并会拿出 40 个
   选择题，而其中 38 个只有一个合理答案。
3. **未决定就不写**。`render()` 在有未决定项时抛错，不生成"带标记的半成品"再让用户去收尾。
4. **备份必须在写之前**。`resolve` 自己会备份，但那时工作文件已是合并结果；原始冲突内容
   只在写之前的备份里。写入后立刻 `resolve`，两边顺序不能换。

三个版本从 `svn info --xml` 的 `<conflict>` 块读（`prev-base-file` / `prev-wc-file` /
`source-right` 的 revision），不从文件名猜：同一文件被更新多次后会留下多个 `.r*`。

## 演示数据与引导（S5-2 配套）

三方合并是**最难自助体验**的功能：要两份工作副本、一次已提交的改动、一次冲突的本地改动，
还要 `svnadmin`。为此 `DemoWorkspace` 在本机生成完整场景，应用和脚本共用同一份定义：

- 应用：欢迎页「想先试试三方合并？」与「帮助 → 试一次三方合并…」→ 生成并直接打开工作副本。
- 终端：`scripts/create-conflict-demo.sh`，转发给 `opensvn-probe demo`。
- 位置：`~/OpenSVN 合并演示`。目录带 `.opensvn-demo` 标记；若目标目录存在且没有标记，
  生成器**拒绝执行**而不是覆盖——一个"生成示例"的命令不该有能力删掉用户的东西。
- 不联网：仓库是 `file://`。

样本刻意做成三类，因为"每个文件都冲突"会教错东西：

| 文件 | 用户会看到 |
|---|---|
| `src/calculator.swift` | 3 处自动合并，1 处需要决定 |
| `docs/config.md` | 2 处自动合并，1 处需要决定 |
| `docs/发布说明.md` | 中文文件名，同样可以合并 |
| `docs/属性冲突.txt` | 属性冲突——三方合并处理不了，需整体选一边 |
| `src/util.swift` | 只有服务器改过，更新时已自动合并 |

`DemoWorkspaceTests` 断言的是**这个混合比例**（`merged.conflicts.count == 1`，且渲染结果里
既有我的"本地版本"又有服务器的"避免 -0"），不是"文件生成了"。样本退化时，测试先红。

引导分三层，每层回答一个不同的问题：

1. 变更页顶部 `ConflictGuideBanner`——**这里有冲突，可以做什么**。直接给「开始三方合并」，
   不再只藏在右键菜单第二层。
2. 合并编辑器顶部三步条——**这三栏是什么关系**。每张冲突卡还有一行原因说明。
3. 编辑器底部——**为什么按钮还是灰的**（还有 N 处未决定）。

### 一个反复出现的布局陷阱

`NavigationSplitView` 不能放进 `VStack`。它会上报自己的理想高度（本机 1737 pt），把窗口
内容撑到远超窗口尺寸：侧边栏空白、文件列表滚动到只剩最后几行。恢复横幅因此放在 **detail 列
内部**，而不是横跨整个窗口。

同理，下列写法也会重新触发：窗口内容上的 `.frame(minWidth:minHeight:)`、
`.windowResizability(.contentMinSize)`。正确做法是只设 `.defaultSize`，并让
`RepositoryDetailView` 用 `GeometryReader` 给内容列一个实测高度——只写
`.frame(maxHeight: .infinity)` 时，文件列表会按内容自适应并滚出可视区。

## 未实现（按阶段）

- 内置运行时打包：脚本已写（`scripts/bundle-svn-runtime.sh`），未接入 CI。
- Windows 端：**尚未开始**。上一版骨架一次都没编译通过，已于 2026-10-18 清空；重做时需要同时恢复代码、CI 与引导脚本。
- 中断恢复的**应用进程级**验证：日志本身有 12 个测试，工作副本侧已由 `F9-sigkill-mid-commit` 覆盖（kill 客户端 → 锁定 → Cleanup → 重新提交），缺的是杀掉 GUI 进程再重启的自动化（需要界面自动化）。
- 故障注入剩余的 F5（密码认证端到端）与 F1–F7 的"提示质量"部分；F3–F7 目前已经**失败得安全**，缺的是解释文案。
- 发布流水线：`release.yml` 只产出未签名产物，且拒绝发布——签名与公证属阶段 6。
