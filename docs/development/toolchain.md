# 工具链版本（固定基准）

> 更新日期：2026-10-18
> 目的：降低构建漂移。**CI 是唯一基线**；本地可以更新，但新版本通过不代表 CI 通过（见「已知偏差」）。

## 1. 基线（CI，具有否决权）

以下版本取自 2026-10-18 的实际 CI 运行（run 39102323161，`macos-15` runner）：

| 组件 | 固定版本 | 说明 |
|---|---|---|
| runner 镜像 | `macos-15` | macOS 15.7.9 |
| Xcode | 16.4 | runner 默认，**不 pin 具体 build**，随镜像更新 |
| Swift | 6.1.2 | 语言模式 `6`；这是代码必须满足的最严格编译器 |
| SwiftPM tools | 6.0 | `Package.swift` 首行，低于编译器版本，正常 |
| Apache Subversion CLI | runner 自带（1.14.x） | 支持区间 1.10 ≤ v < 2.0；缺失时工作流用 Homebrew 补装 |
| svnadmin | 同上 | 仅测试仓库使用，不是用户依赖 |
| Python | 3.12+（runner 自带） | 仅 `scripts/` 使用，无第三方包 |
| macOS 部署目标 | 14.0 | `Package.swift` 与 `Info.plist` 的 `LSMinimumSystemVersion` |

## 2. 开发机（可以更新，但不是基线）

| 组件 | 本机版本 | 说明 |
|---|---|---|
| macOS | 27.0.1 | 高于最低目标，属于「向低兼容」验证 |
| Xcode / Swift | 27.1 / 6.4 | **比 CI 新**，更多并发写法会被接受 |
| Apache Subversion CLI | 1.14.5（Homebrew） | 与 CI 同主版本 |
| Git | 系统自带 | |

## 3. Windows 工具链（尚未实测）

> 这些版本来自规划文档，**没有一台机器实际编译过**。`vswhere -latest` 的实测输出写入本表之前，任何一条都不可信。

| 组件 | 固定版本 | 说明 |
|---|---|---|
| Windows | 11（build 22000+） | 主目标，见 ADR-0004 |
| Visual Studio | 2022 17.x / 2026（含 **Desktop development with C++** 与 **Windows App SDK C++ templates**） | 版本以 `vswhere -latest` 实际输出为准 |
| MSVC 平台工具集 | v143 | `OpenSVN.vcxproj` 固定，不用 `$(DefaultPlatformToolset)` |
| C++ 标准 | C++20（`stdcpp20`） | 不用 C++23 预览特性 |
| Windows SDK | 10.0.26100.0（最低 10.0.22000.0） | 工程固定，不用 `10.0`（浮动到最新） |
| Windows App SDK | 1.6.250205002（NuGet 固定） | 浮版本是构建漂移的主要来源 |
| vcpkg | manifest 模式，`builtin-baseline` 2024.11.16 | 仅测试工程使用（GoogleTest 1.14） |

`apps/windows` 的任何版本调整都必须同时更新本表与工程文件；`windows-ci.yml`
里的 `WINDOWS_SDK` 变量是第三处，三者不一致即视为配置错误。

## 复现命令

```bash
xcodebuild -version
swift --version
svn --version --quiet
python3 --version
```

## CI 对齐规则

- `macos-ci.yml` 使用固定 `macos-15` runner 镜像，而不是 `macos-latest`。
- 工作流里的 `EXPECTED_SWIFT` / `EXPECTED_MACOS` 只是**断言**，不是安装指令；runner 漂移时输出 `::warning::`，需在同一个 PR 里更新本文与这两个变量。
- 运行时（内置 svn）版本变更必须同时更新：本文、`tests/fixtures/README.md`、`NOTICE` 的第三方清单。
- **并发相关的改动以 CI 为准。** 本机 Swift 6.4 比 CI 的 6.1.2 宽松，下面这类诊断只在 CI 出现。

## 已知偏差

- **SE-0461（Swift 6.2 起默认）**：非隔离 async 函数默认在调用方 actor 上执行。6.1 里普通 async 闭包参数仍被当作 nonisolated，泛型结果 `T` 必须 `Sendable`，否则报
  `non-sendable result type 'T' cannot be sent from nonisolated context`。
  `RepositorySession.withAuthRetry` 就踩过这个坑：本机 6.4 通过、CI 6.1.2 失败。
  写这类辅助函数时，显式标注 `@MainActor` 闭包或约束 `T: Sendable`。
- 开发机 macOS 27.0.1 高于最低目标，属于「向低兼容」验证，不能替代阶段 6 的干净系统测试。
- Intel x86_64 尚未验证；若启用，需要在本表新增一行并补 CI。
- 本机 `swift build` 会被 manifest 的 `sandbox_apply` 拒绝，需 `--disable-sandbox`
  并把 `HOME` 指到仓库内（见 README）。CI 不受影响。
