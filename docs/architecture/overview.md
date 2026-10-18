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

## 未实现（按阶段）

- 冲突解决向导（阶段 5）：目前只有策略选择 + 二次确认，没有三方合并编辑器。
- 中断恢复（S5-4）：尚未记录“进行中的操作”。
- 内置运行时打包：脚本已写（`scripts/bundle-svn-runtime.sh`），未接入 CI。
- Windows 端：完全未开始。
