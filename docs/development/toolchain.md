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
