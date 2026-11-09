<p align="right">
  <a href="README.md">English</a> · <b>简体中文</b>
</p>

# OpenSVN

现代化、免费、开源的原生 Apache Subversion 图形客户端，支持 macOS 与 Windows。

OpenSVN 把真实的 `svn` 命令作为子进程调用，不重新实现工作副本格式，所以命令行里能用的仓库在这里照旧能用。
macOS 端是 Swift 6 + SwiftUI/AppKit；Windows 端是 C++20 核心 + C ABI + C# WinUI 3 外壳。
不使用 Electron、Qt 或内嵌浏览器。

> **当前状态：`v0.1.0-dev`，还没有打过发布 tag。** 打 tag 会产出
> `OpenSVN-<ver>-macos-arm64.zip` 与签好名的 `SHA256SUMS` 并直接发布，所以可下载的构建
> 只差一个 `git tag`；在此之前，唯一的应用是你自己构建的 `build/OpenSVN.app`。
> macOS 是成熟的一侧：**361 个测试 / 66 个套件**全部通过，其中包含对真实 svn 1.14.5
> 的往返验证，整条工作副本流程都能在窗口里走完。Windows 端可以构建、**110 个原生测试**
> 全部通过，但只跑过 `fake_svn` 这个测试替身，从未在真实 `svn.exe` 上运行，也没有安装包。
> 分平台细节见 [apps/macos/README.md](apps/macos/README.md)、
> [apps/windows/README.md](apps/windows/README.md)。

## 已实现的功能

以下是 macOS 今天的状态。表里每一项在界面上都有入口，不是只存在于服务层、还在等按钮的 API。

| 方面 | 可用能力 |
| --- | --- |
| 工作副本 | 检出、添加已有工作副本、还原、删除、清理、重定位、按需 pristines（需 svn 1.15+） |
| 提交 | 显式选择文件、提交说明、属性与 `svn:ignore`；有冲突不能提交，提交失败保留说明与勾选 |
| 更新 | 先出预检表列出将要进来的修订，确认后才动磁盘 |
| 冲突 | 三方合并编辑器、可配置的外部合并工具、逐文件解决并备份原文件 |
| 历史 | 日志落盘缓存、本地即时筛选、服务器端搜索、跟随重命名的单文件历史、`svn blame`、差异面板 |
| 分支 | 合并（mergeinfo 驱动或两 URL 比较，`-r N:M` / `-c N`、`--record-only`、`--ignore-ancestry`）、切换、合并记录 |
| 仓库 | 不检出也能浏览任意 URL 目录树、远端 mkdir/copy/move/delete、打 tag、导入本地目录、按修订号导出 |
| 锁 | 加锁、解锁、强制抢占，逐路径显示持有者与锁定说明 |
| 组织 | 变更列表及筛选、`svn:externals` 单独归类并排除在提交边界之外 |
| 连接 | 单次操作的 HTTPS 证书信任、代理、SASL、客户端证书、密码存 Keychain |
| 更新 | 读取发布列表比对版本、下载后算 SHA-256、校验签名清单，确认后退出时替换并重启。信任锚有两种：项目自有的 Ed25519 密钥（免费），或与本应用一致的 Developer ID 团队（需证书） |

Windows 端实现的是同一套契约的一个更窄子集；上表是 macOS 的陈述，不是跨平台承诺。

## 尚未实现

- Apple 签名与公证。发布产物是 ad-hoc 签名 + 对 `SHA256SUMS` 的 Ed25519 签名；代价与手动下载时 Gatekeeper 要求的一次性授权写在 [packaging/macos/README.md](packaging/macos/README.md)。没有 Apple 账号就去不掉这一步。
  Mac App Store 路线已评估并否决，三处结构性冲突记录在 [packaging/macos/distribution-decision.md](packaging/macos/distribution-decision.md)。
- 除 `svnadmin create` 之外的仓库管理：没有 `svnsync`、没有 dump/load 工作台、不能编辑 hook。
- Windows 端：安装包、MSIX、签名、内置 `svn.exe`、三方合并编辑器。

## 仓库结构

```text
apps/macos/            Swift Package（OpenSVNCore + SwiftUI 应用）与 Xcode 工程
apps/windows/          C++20 核心 + C ABI + C# WinUI 3 应用（未打包）
specifications/        跨平台行为契约（唯一事实来源）
testdata/              采集的 `svn --xml` 输出，契约测试的解析样本
scripts/               环境引导、测试仓库、fixture 采集、打包与发布自检
packaging/{macos,windows}/  签名、公证、安装包定义
third_party/           第三方依赖清单与许可证义务
.github/workflows/     macOS、Windows、CodeQL 与发布闸门
```

两个平台共享 `specifications/` 里的契约，不共享代码。

## 快速上手（macOS）

先按下一节把应用构建出来。从发布页下载的构建是 ad-hoc 签名（没有 Apple 开发者证书），
首次打开会被 Gatekeeper 拦一次：macOS 14 可以右键 → 打开；**macOS 15 起右键已失效**，要
双击一次、关掉提示，再去「系统设置 → 隐私与安全性」点「仍要打开」并输入密码。这只发生一次，
之后「检查更新…」装的新版本不再经过 Gatekeeper。自己从源码构建的产物没有 quarantine 标记，
不会有这一步。界面是中文的，下面写的都是界面上真实的字。

1. **检出** — 工具栏「检出」，或「检出仓库…」（⇧⌘O），填「仓库 URL」「目标目录」。只想看看、
   不留工作副本，就用「只看仓库（不检出）…」。
2. **提交** — 「变更」页列出改动，点「去提交」到「提交」页，勾选文件、写「提交说明」，
   点「提交 N 项」（⌘↵）。
3. **更新** — 「更新」（⇧⌘U）先给预检表，点「仍然更新」才执行。
4. **冲突** — 「变更」页顶部橙色引导条给「开始三方合并」；冲突行还有「三方合并」按钮与
   「解决冲突」菜单。
5. **历史** — 「历史」页随输入即时本地筛选；要查全库用「在服务器上搜索「…」」。
   「差异」看差异，「注解」看 `svn blame`。
6. **分支** — 「分支」菜单里有「合并…」「切换分支…」「合并记录…」。合并面板会先算给你看要改什么。
7. **锁** — 右键路径：「锁定…」「解除锁定…」「强制抢占锁定…」。

长任务在「任务中心」（⇧⌘J）里报进度，结束会发系统通知。自建 CA 的服务器在「设置 → 连接」里配。

## 构建与运行（macOS）

依赖：macOS 14+（Apple silicon；x86_64 不是支持目标）、Xcode 16+（Swift 6 工具链）、
Apache Subversion 1.10+。1.10 是 `--password-from-stdin` 出现的版本，而它是「密码不进 argv」
的唯一实现方式。release 构建自带 `svn` 运行时；debug 构建不带，所以本机要有一个在 `PATH`
或常见安装位置。

```bash
scripts/bootstrap-macos.sh                  # 检查工具链与 svn
cd apps/macos && swift build                # 构建核心层与应用
cd apps/macos && swift test                 # 361 个测试 / 66 个套件，需要真实 svn
scripts/build-macos-app.sh                  # 生成 build/OpenSVN.app（debug，不带运行时）
CONFIG=release scripts/build-macos-app.sh   # release 构建，自带 svn 运行时
open build/OpenSVN.app
```

产物是 ad-hoc 签名，仅供本机使用；签名与公证见
[packaging/macos/README.md](packaging/macos/README.md)。`scripts/build-macos-app.sh` 用
`BUNDLE_SVN=0|1` 控制是否内置运行时，脚本开头的注释写清了每种组合的后果。

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
cd apps/macos && swift test             # 361 个测试 / 66 个套件
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

## 构建与运行（Windows）

依赖：Windows 11 x64、装有 **Desktop development with C++** 的 Visual Studio 2022/2026、
Windows SDK 10.0.26100+、CMake 3.25+、.NET 10 SDK，以及用来实际运行应用的 `svn.exe` 1.10+。
构建与测试不需要装 Subversion：110 个原生测试跑在 `fake_svn.exe` 与采集的 fixture 上。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -Configuration Debug
```

产物位于
`apps/windows/src/ui/OpenSVN.App/bin/x64/Debug/net10.0-windows10.0.26100.0/win-x64/`。
应用在 Windows App SDK/.NET 意义上自包含；原生桥仍链接 MSVC 运行库，目标机若未装
Visual Studio，需要 VC++ 2015-2022 Redistributable（x64）。MSIX 与安装器尚未实现，
打包形式仍待实测定稿。架构、原生桥、安全约束、数据目录与全部未实现项见
[apps/windows/README.md](apps/windows/README.md)。

## 安全原则

1. 子进程一律以独立参数数组启动，禁止拼接 Shell 字符串。
2. 密码不出现在命令行参数、日志或设置中；通过 stdin 与 macOS Keychain / Windows Credential Manager 传递与保存。
3. 危险操作（`revert`、`delete`、冲突解决）必须在**服务层**要求显式确认，不能只靠界面拦截。
4. 同一工作副本上的写操作串行化。
5. 所有长耗时任务异步执行、可取消、有进度。

具体条文见 `specifications/`；漏洞上报见 `SECURITY.md`。

## 许可证

Apache-2.0，见 `LICENSE` 与 `NOTICE`。OpenSVN 与 Apache Software Foundation 无隶属关系。
