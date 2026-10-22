# ADR-0004：平台与工程配置（macOS）

> 状态：**已采纳**
> 日期：2026-10-18
> 关联：`apps/macos/Package.swift`、`apps/macos/OpenSVN.xcodeproj`、`docs/development/toolchain.md`
> 影响阶段：阶段 1（工程配置）、阶段 6（打包签名）、阶段 7（文档）

## 背景

规范 §2 给出的是“暂定”的系统版本与架构，要求用实际 SDK 与工程配置确认，而不是照抄框架的理论下限。另外 S0-4 需要决定 macOS 是否启用 App Sandbox。

## 决策

| 项目 | 结论 |
|---|---|
| 最低系统版本 | **macOS 14.0**（`MACOSX_DEPLOYMENT_TARGET = 14.0`） |
| 语言模式 | **Swift 6**（`SWIFT_VERSION = 6.0`，严格并发检查生效） |
| 首期架构 | **arm64**；工程未开启 `ONLY_ACTIVE_ARCH` 之外的裁剪，后续可直接出 universal2 |
| App Sandbox | **关闭**（`ENABLE_APP_SANDBOX = NO`） |
| Hardened Runtime | 阶段 1–5 关闭；阶段 6 签名时开启并逐项评估（子进程、任意路径访问） |
| 工程形态 | `apps/macos/OpenSVN.xcodeproj`（app target）+ 同目录 `Package.swift`（`OpenSVNCore` 库 + 测试） |
| Bundle ID | `cn.opensvn.app` |
| 本地签名 | ad-hoc（`CODE_SIGN_IDENTITY = "-"`） |

## 理由

### 为什么关沙盒

OpenSVN 的三条核心需求与沙盒直接冲突：

1. 打开任意路径下的工作副本（沙盒只能访问用户显式选择的文件/目录，且需 security-scoped bookmark 持久化）；
2. 启动 `svn` 子进程（沙盒应用不能执行包外任意可执行文件，内置运行时也需要额外 entitlement 与签名安排）；
3. 读写 `.svn` 内部数据库与临时文件。

强行适配的代价是：每个工作副本都要保存 bookmark、内置运行时签名链更复杂、`svn` 子进程在某些路径下仍会失败。MVP 阶段选择关闭沙盒，接受“不能上架 App Store”的后果，分发走 Developer ID + 公证（ADR-0003 已记录该路径）。

如果将来要上架，需要重开本 ADR，并评估：内置 runtime 的嵌套签名、security-scoped bookmark 的迁移、以及子进程在沙盒下的可行性。

### 为什么 Xcode 工程 + SPM 包并存

- 核心层（进程、解析、模型）必须是可测试的库：SPM 的 `swift test` 是 CI 上最便宜、最稳定的测试入口，不依赖 Xcode scheme。
- 应用层需要 `.app`、Info.plist、签名与资源：Xcode 工程是官方且最少魔法的路径。
- 工程通过 `XCLocalSwiftPackageReference` 引用同目录包，只有一份源码，不存在复制。

代价：Xcode 与 SPM 各自维护一份构建缓存；`swift build` 与 `xcodebuild` 的编译参数需要保持一致（Swift 6、macOS 14，已在两处固定）。

## 后果

- **正向**：`open Package.swift` 与 `open OpenSVN.xcodeproj` 都能工作；CI 可以只跑 `swift test`。
- **负向**：无法上架 Mac App Store；`xcodebuild` 需要 `-derivedDataPath` 指向仓库内目录，否则 CI 缓存策略要单独设计。
- **对阶段 6 的约束**：公证前必须开启 Hardened Runtime 并验证内置 `svn` 及其 dylib 的签名顺序（ADR-0003 已记录“由内向外”）。

## 若改变

- 提高最低版本 → 可用的 SwiftUI API 变多，但会缩小用户面；需同步更新 `compatibility.md` 与 CI runner。
- 开启沙盒 → 影响 S1-4 工程配置、S2-8 进程调用、S6-1 打包、S6-2 公证，属于跨阶段返工。
