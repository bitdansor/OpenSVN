# OpenSVN

现代化、免费、开源、原生的 Apache Subversion（SVN）图形客户端。

macOS 端使用 Swift 6 + SwiftUI/AppKit；Windows 端（规划中）使用 C++20 + WinUI 3。
不使用 Electron、Qt 或内嵌浏览器。

> 当前状态：`v0.1.0-dev`，macOS 核心层与界面正在开发。Windows 端已于 2026-10-18
> 清空，后续从零重做。

## 仓库结构

```text
apps/macos/            Swift Package（OpenSVNCore + SwiftUI 应用）与 Xcode 工程
apps/windows/          预留给 Windows 端，当前刻意保持为空
specifications/        跨平台行为契约（唯一事实来源）
tests/fixtures/        采集的 `svn --xml` 输出，用于契约测试
tests/scenarios/       故障注入场景目录（F1–F15）与将来的执行器
tests/integration/     跨平台的慢速工作副本场景
scripts/               环境引导、测试仓库、fixture 采集、打包与发布自检
packaging/{macos,windows}/  签名、公证、安装包定义（阶段 6）
docs/                  架构、ADR、用户手册、发布说明
third_party/           第三方依赖清单与许可证义务
```

哪些是真的验证过的，写在 [apps/macos/README.md](apps/macos/README.md)（已实现、有测试）。
`apps/windows/` 只剩占位文件：之前那套 C++/WinUI 骨架一次都没编译通过，
所以直接删掉，而不是留一份没人能验证的声明。`windows-ci.yml` 与
`bootstrap-windows.ps1` 已随之移除，将来必须与代码一起回来。

## 构建与运行（macOS）

依赖：macOS 14+、Xcode 16+（Swift 6 工具链）、Apache Subversion CLI 1.8+。

```bash
scripts/bootstrap-macos.sh          # 检查工具链与 SVN
cd apps/macos && swift build        # 构建核心层与应用
cd apps/macos && swift test         # 单元测试 + 契约测试
scripts/build-macos-app.sh          # 生成 build/OpenSVN.app
open build/OpenSVN.app
```

签名与公证流水线尚未接入，产物为 ad-hoc 签名，仅供本机使用。

### 试一下三方合并

合并编辑器不好凭空试：它需要两份工作副本、一次已提交的改动和一次冲突的本地改动。
应用和脚本都能在本机把这套东西直接造出来（`file://` 仓库，不联网）：

```bash
scripts/create-conflict-demo.sh        # ~/OpenSVN 合并演示
```

或者在应用里：欢迎页点「想先试试三方合并？」，或菜单「帮助 → 试一次三方合并…」。
生成后会自动打开工作副本，「变更」页顶部会出现橙色引导条，点「开始三方合并」即可。

样本里有三类情况：能自动合并的改动、需要你决定的文本冲突、以及一个**不能**三方合并的
属性冲突——后者需要整体选一边，引导条会说明区别。

### 自检

```bash
scripts/bootstrap-macos.sh              # 缺什么依赖
cd apps/macos && swift test             # 126 个测试 / 20 个套件，需要真实 svn
python3 scripts/verify-release.py       # VERSION / CHANGELOG / Info.plist / fixture 一致性
python3 scripts/verify-release.py --bundle build/OpenSVN.app
```

`verify-release.py` 在不一致时以非零码退出，适合放进钩子或发布前手动执行。其中凭据扫描只是粗略的
兜底：只在**明确泄露**（URL 里带账号密码）时判失败，其余形似代码的写法只报警告。

### 受限环境

`swift build` 会写 `~/.swiftpm` 与 `~/Library/Caches`。若环境拒绝访问这些路径（报错里出现
`Invalid manifest` 或 `~/.swiftpm` 下的 security 目录），把 SwiftPM 的家目录指到可写位置即可，
不要和沙盒权限硬碰：

```bash
HOME="$PWD/.build-home" swift build
HOME="$PWD/.build-home" swift test
```

`.build-home` 已被 git 忽略。

## 安全原则

1. 子进程一律以独立参数数组启动，禁止拼接 Shell 字符串。
2. 密码不出现在命令行参数、日志或设置中；通过 stdin 与 macOS Keychain 传递与保存。
3. 危险操作（`revert`、`delete`、冲突解决）必须在**服务层**要求显式确认，不能只靠界面拦截。
4. 同一工作副本上的写操作串行化。
5. 所有长耗时任务异步执行、可取消、有进度。

具体条文见 `specifications/`。

## 许可证

Apache-2.0，见 `LICENSE` 与 `NOTICE`。OpenSVN 与 Apache Software Foundation 无隶属关系。
