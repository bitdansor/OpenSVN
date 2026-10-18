# 架构概览（macOS）

```text
SwiftUI Views
   │  (只读状态 + 触发动作)
   ▼
AppState / RepositorySession / TaskCenter      @MainActor, Observation
   │  (无 shell 拼接、无凭据持久化)
   ▼
SVNService (actor)                             ← 唯一 svn 入口
   ├── WCWriteGate     每工作副本写串行化
   ├── CredentialStore Keychain / InMemory
   ├── SVNProcessRunner 参数数组 / 双管道 / 取消 / 超时
   ├── SVNXMLParser     status / log / info
   └── SVNDiscovery     内置 → 显式 → PATH → 常见位置
   │
   ▼
svn CLI (child process)
```

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
3. **`TaskCenter` 是唯一的取消入口**：界面不持有 `Task`，取消通过任务条目进行，避免“视图销毁导致任务泄漏”。
4. **`RepositorySession` 不引用 `AppState`**：通过 `onCredentialRequired` 闭包反向请求凭据，避免双向持有。
5. **进度回调是结构体而非闭包**：`SVNProgressReporter` 可自由跨层传递，避免 `@escaping` 污染整条调用链。

## 数据流（一次提交）

1. `CommitView` 调 `RepositorySession.commit()`。
2. Session 校验说明非空、勾选非空。
3. `TaskCenter.run` 创建任务条目，进入 `SVNService.commit`。
4. Service 取得写锁 → 对每个路径重新 `status`（发现冲突即中止）→ 启动 `svn commit`。
5. Runner 并发读 stdout/stderr，逐行回调进度；任务中心更新详情。
6. 成功 → Service 返回 `CommitSummary`；Session 清空说明、刷新状态、重载历史。
7. 失败 → `SVNErrorMapper` 分类 → Session 呈现错误；任务条目保留。

## Windows 端（骨架，未编译）

Windows 实现与 macOS 逐层对应，但不共享代码——共享的是 `specifications/` 的行为契约（规划 §3）。

| 层 | 文件 | 职责 | 当前状态 |
|---|---|---|---|
| 模型 | `apps/windows/OpenSVN/Models/SVNModels.*` | 字段语义与 macOS 一一对应；无 Windows 头文件 | 已在 macOS 上用 clang 编译并断言通过 |
| 进程 | `Services/SVNProcessRunner.*` | `CreateProcessW` + 参数数组、Job Object 杀进程树、双线程排空管道、`std::stop_token` 取消 | 未编译 |
| 解析 | `Services/SVNXMLParser.*` | `Windows.Data.Xml.Dom`，零外部依赖 | 未编译 |
| 凭据 | `Services/CredentialStore.*` | Credential Manager（`CredReadW`/`CredWriteW`），目标名前缀 `OpenSVN:` | 未编译 |
| 服务 | `Services/SVNService.*` | 命令编排、`--password-from-stdin`、错误分类、`WorkingCopyGate` | 未编译 |
| 界面 | `App.xaml` / `MainWindow.xaml` + `Views/` | WinUI 3 外壳，五页在阶段 4 填充 | 未编译 |

两个平台的关键差异（不是缺陷，是记录）：

1. **参数传递**：Win32 只接受一整条命令行字符串。R1 在这里的含义是"由参数数组**拼**出命令行并逐项加引号"，绝不经过 `cmd.exe`；`QuoteArgument` 单独暴露出来就是为了能被单测。
2. **取消**：macOS 用 SIGTERM → SIGKILL；Windows 用 Job Object + `TerminateJobObject`，否则 `svn` 的子进程会变成孤儿并占住工作副本锁。
3. **路径编码**：`path.string()` 会走当前代码页并毁掉中文路径，必须走 `u8string()`；同时 `app.manifest` 声明 UTF-8 活动代码页与 `longPathAware`。

## 目录映射（规划 §4 ↔ 实际）

规划 §4 假定 macOS 是纯 Xcode 工程；实际以 SwiftPM 为主，原因见 ADR-0007。对照关系：

| 规划 §4 | 实际 | 说明 |
|---|---|---|
| `apps/macos/OpenSVN/Services/` | `apps/macos/Sources/OpenSVNCore/{Process,Parsing,Discovery,Services,Support}/` | 核心层拆成可独立测试的 target |
| `apps/macos/OpenSVN/Models/` | `apps/macos/Sources/OpenSVNCore/Models/` | 同上 |
| `apps/macos/OpenSVN/{App,Views,ViewModels}/` | `apps/macos/Sources/OpenSVN/{App,Views,ViewModels,Models}/` | 界面层 |
| `apps/macos/OpenSVNTests/` | `apps/macos/Tests/OpenSVNCoreTests/` | Swift Testing |
| `apps/macos/OpenSVNUITests/` | 暂无 | 界面测试要等打包稳定（阶段 6） |
| `apps/windows/**` | 与规划一致 | C++ 侧不需要拆分库 |

`python3 scripts/verify-release.py --layout` 会逐项检查这张表对应的目录与锚点文件是否真的存在（空目录会被判失败，因为 git 不跟踪空目录）。

## 未实现（按阶段）

- 冲突解决向导（阶段 5）：目前只有策略选择 + 二次确认，没有三方合并编辑器。
- 中断恢复（S5-4）：尚未记录“进行中的操作”。
- 内置运行时打包：脚本已写（`scripts/bundle-svn-runtime.sh`），未接入 CI。
- Windows 端：目录、模型、服务层与 WinUI 外壳已写，但**一次都没有在 Windows 上编译过**；`windows-ci.yml` 因此是非阻塞状态，详见 `apps/windows/README.md`。
- 发布流水线：`release.yml` 只产出未签名产物，且拒绝发布——签名与公证属阶段 6。
