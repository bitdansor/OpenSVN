# 工具链版本（固定基准）

> 更新日期：2026-10-18
> 目的：降低构建漂移。CI、本地开发、发布必须使用同一组版本；升级需单独 PR 并更新本文。

| 组件 | 固定版本 | 说明 |
|---|---|---|
| macOS | 14.0+（开发机 27.0.1） | 最低部署目标 14.0 |
| Xcode | 27.1（Build 27A9275） | 与 CI runner 的默认 Xcode 对齐后再固定 |
| Swift | 6.4（swiftlang-6.4.0） | 语言模式 `6` |
| SwiftPM tools | 6.0 | `Package.swift` 首行 |
| Apache Subversion CLI | 1.14.5（Homebrew） | 支持区间 1.10 ≤ v < 2.0 |
| svnadmin | 1.14.5 | 仅测试仓库使用，不是用户依赖 |
| Python | 3.13（脚本辅助） | 仅 `scripts/` 与 Release 校验使用，无第三方包 |
| Git | 系统自带 | |
| **Windows** | 11（build 22000+） | 主目标，见 ADR-0004 |
| Visual Studio | 2022 17.x / 2026（含 **Desktop development with C++** 与 **Windows App SDK C++ templates**） | 版本以 `vswhere -latest` 实际输出为准，写入本表后才可采信 |
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
- 若 runner 默认 Xcode 与本文不一致，工作流中显式 `xcode-select` 或使用 `maxim-latest` 前先改本文。
- 运行时（内置 svn）版本变更必须同时更新：本文、`tests/fixtures/README.md`、`NOTICE` 的第三方清单。

## 已知偏差

- 开发机 macOS 27.0.1 高于最低目标，属于“向低兼容”验证，不能替代阶段 6 的干净系统测试。
- Intel x86_64 尚未验证；若启用，需要在本表新增一行并补 CI。
