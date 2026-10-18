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

共享的是 `specifications/` 的行为契约（规划 §3），不是代码。重做时值得先读的三条差异：

1. **参数传递**：Win32 只接受一整条命令行字符串。R1 在这里的含义是"由参数数组**拼**出命令行并逐项加引号"，绝不经过 `cmd.exe`。
2. **取消**：macOS 用 SIGTERM → SIGKILL；Windows 必须用 Job Object + `TerminateJobObject`，否则 `svn` 的子进程会变成孤儿并占住工作副本锁。
3. **路径编码**：`path.string()` 会走当前代码页并毁掉中文路径，必须走 `u8string()`；同时 `app.manifest` 需声明 UTF-8 活动代码页与 `longPathAware`。

## 目录映射（规划 §4 ↔ 实际）

规划 §4 假定 macOS 是纯 Xcode 工程；实际以 SwiftPM 为主，原因见 ADR-0007。对照关系：

| 规划 §4 | 实际 | 说明 |
|---|---|---|
| `apps/macos/OpenSVN/Services/` | `apps/macos/Sources/OpenSVNCore/{Process,Parsing,Discovery,Services,Support}/` | 核心层拆成可独立测试的 target |
| `apps/macos/OpenSVN/Models/` | `apps/macos/Sources/OpenSVNCore/Models/` | 同上 |
| `apps/macos/OpenSVN/{App,Views,ViewModels}/` | `apps/macos/Sources/OpenSVN/{App,Views,ViewModels,Models}/` | 界面层 |
| `apps/macos/OpenSVNTests/` | `apps/macos/Tests/OpenSVNCoreTests/` | Swift Testing |
| `apps/macos/OpenSVNUITests/` | 暂无 | 界面测试要等打包稳定（阶段 6） |
| `apps/windows/**` | 暂无（2026-10-18 清空） | 重做时按规划 §4 布局；不要为了对齐目录而提前建空壳 |

`python3 scripts/verify-release.py --layout` 会逐项检查这张表对应的目录与锚点文件是否真的存在（空目录会被判失败，因为 git 不跟踪空目录）。

## 未实现（按阶段）

- 冲突三方合并编辑器（阶段 5 后半）：策略选择、二次确认、解决前备份、解决后残留标记校验都已实现（`ConflictGuard` + `ResolveOutcome`），缺的是并排合并界面。
- 中断恢复（S5-4）：尚未记录“进行中的操作”。
- 内置运行时打包：脚本已写（`scripts/bundle-svn-runtime.sh`），未接入 CI。
- Windows 端：**尚未开始**。上一版骨架一次都没编译通过，已于 2026-10-18 清空；重做时需要同时恢复代码、CI 与引导脚本。
- 发布流水线：`release.yml` 只产出未签名产物，且拒绝发布——签名与公证属阶段 6。
