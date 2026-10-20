# ADR-0003：SVN 运行时分发策略

> 状态：**macOS 运行时已实现并接入 CI（S6-1 / S6-6）；签名与公证流水线已完成但缺证书，未做真实公证（S6-2）；Windows 待验证**
> 日期：2026-10-18（决策）/ 2026-10-20（实施进展）
> 关联：`OpenSVN_开发执行计划.md` S0-3 / Gate A / K1
> 影响阶段：阶段 1（CI）、阶段 3（进程调用）、阶段 6（打包签名公证）、阶段 7（合规）

## 背景

规范 §2 写死一条硬要求：

> 发布包**不能默认依赖用户自行安装 SVN**：正式版必须明确 CLI 的发现、内置打包或安装依赖策略，覆盖动态库、许可证、签名和公证问题。

这句话把「SVN 从哪来」变成了必须前置决策的架构问题，而不是打包期的补充工作。三种候选路线：

- **方案 A｜内置打包**：把 `svn` 可执行文件及其动态库闭包放进应用包内。
- **方案 B｜依赖系统已安装**：运行时探测用户机器上的 `svn`，缺失则阻止使用并引导安装。
- **方案 C｜首次启动引导安装**：应用内下载/安装运行时。

## 实测数据（macOS，本机）

在 macOS 27.0.1 / arm64 / Xcode 27.1 环境下，对 Homebrew 版 `svn 1.14.5` 做了一次完整摸底，
脚本见 `scripts/spike-bundle-svn-macos.sh`（可复现）。

| 项目 | 结果 |
|---|---|
| 直接依赖 | 26 个（dylib + 系统 framework） |
| 需打包的第三方 dylib | **22 个**（去重后） |
| 打包后体积 | **11 MB** |
| 改写方式 | `install_name_tool -change` 全部改为 `@rpath/<name>`，主程序注入 `@executable_path/../Frameworks` |
| 宿主路径残留 | 0 |
| 签名 | 内层 dylib → 主程序 → bundle，ad-hoc 全部通过 |
| 独立运行 | 通过（`svn --version` = 1.14.5） |
| 功能验证 | checkout / add（中文名 + 空格路径）/ commit（中文提交说明）/ update / status --xml / log --xml / diff 全部正常 |

### 两个必须记住的实证结论

1. **Apple Silicon 上必须重签。** 用 `install_name_tool` 改写后若不重签，二进制会被内核直接
   `SIGKILL`（退出码 137），而不是给出「签名无效」的错误提示。这条会以「莫名其妙闪退」的形式
   出现，极难排查。签名顺序必须是**由内向外**：dylib → 主程序 → bundle。
2. **符号链接会让闭包收集出错。** 依赖里出现的是 `/opt/homebrew/opt/utf8proc/lib/libutf8proc.3.dylib`，
   真实文件是 `libutf8proc.3.2.3.dylib`。按 realpath 的 basename 去改写会指向不存在的文件。
   必须以**实际拷入包内的文件名**为准建立映射。

## 许可证实测

| 组件 | 许可证 |
|---|---|
| subversion / serf / apr / apr-util / openssl@3 | Apache-2.0 |
| lz4 | BSD-2-Clause |
| utf8proc | MIT AND Unicode-DFS-2015 |
| **gettext（libintl）** | **GPL-3.0-or-later AND LGPL-2.1-or-later** |

`libintl.8.dylib` 是唯一的合规复杂点：动态链接 LGPL 库本身可行，但需要随包提供许可证文本、
保留可替换性（不能在签名层面阻止用户替换该 dylib）。更干净的做法是**自建 svn 时加 `--disable-nls`
彻底去掉 libintl 依赖** —— 对中文界面无影响（NLS 只影响 svn 自身的英文提示文案，而我们的 UI 文案
本来就来自应用自身，不读 svn 的翻译）。

## 决策

**采纳方案 A（内置打包）作为 macOS 的默认策略，但保留可覆盖的发现逻辑。**

理由：

1. 11 MB 的体积代价相对于「用户装不上就用不了」的失败模式，完全可接受。
2. 方案 B 与规范 §2 的硬要求直接冲突，只能作为过渡期的开发调试手段。
3. 方案 C 引入下载器、更新器、校验、断点续传等一整套逻辑，与 MVP 阶段目标不符。

配套约束（需在 `svn-operations.md` 与 `compatibility.md` 中落为条文）：

- **默认**使用内置运行时；**设置页允许**指定自定义 `svn` 路径，用于高级用户与排障。
- 发现顺序：显式设置 → 包内内置 → `PATH` 探测 → 报错并给出可执行建议（不得静默失败）。
- 启动时校验内置 `svn --version --quiet` 与 `compatibility.md` 的支持区间，不匹配时明确提示而非静默降级。
- macOS 上**不得**依赖 `PATH` 查找 `svn`：从 Finder/Dock 启动的进程 `PATH` 不含 Homebrew 路径。

### 实施进展（2026-10-20）

S6-1 与 S6-6 已落地，结论与当初摸底一致（22 个 dylib、11 MB），但补上了三个摸底阶段没暴露的问题：

1. **只打包 `svn` 不够。** 应用内「试一次三方合并」会用 `svnadmin create` 建仓库，
   `DemoWorkspace.adminTool()` 是在 `svn` 同目录找 `svnadmin`。只带 `svn` 的话，这个功能
   恰好在「没有装 Subversion 的机器」上坏掉——而那正是内置运行时存在的理由。现在两个都打包。
2. **许可证文本不能指望 Cellar。** 新版 Homebrew 的 bottle 里常常没有 `LICENSE` 文件。
   改为从 `brew info --json=v2` 取 SPDX 标识、文本能取到就取，取不到的**按名字记录**在
   `runtime-manifest.json` 的 `textsMissing` 里。清单同时记录每个打包文件的来源与 SHA-256，
   S7-2 审计有据可查，而不是一个掩盖缺口的绿勾。
3. **「干净机器」不能靠嘴上说。** `scripts/verify-clean-install.sh` 以
   `PATH=/usr/bin:/bin`、空 `HOME`、不继承任何环境变量运行内置工具，再执行
   checkout / add（中文名带空格）/ commit（中文说明）/ update / status --xml / log --xml，
   然后把整个 bundle 拷到另一个目录重跑一遍（验证 `@rpath` 是相对路径），
   最后让应用自己的发现逻辑在 `PATH=/nonexistent` 下解析，断言 `source=bundled` 且路径在包内。

该脚本**不覆盖** Gatekeeper 与公证——那需要一个 Developer ID 和一台全新的 macOS。
它会把自己的适用范围写进 `build/clean-install-report.txt`，不假装发布已通过验证。

`macos-ci.yml` 新增 `runtime` 作业，在每次 PR 上做完整打包 + 校验 + 干净机检查；
`release.yml` 的 macOS 作业同时要求 `--require-bundled-svn`。

### S6-2 签名与公证（2026-10-20）

流水线已写完，但只在「Apple Development」证书上验证过签名与清单刷新这一段：本机没有
Developer ID Application 证书，`notarytool` 也没有凭据，所以**真实公证从未跑过**。

已落地的部分：

- `packaging/macos/entitlements.plist` **刻意为空**。不加沙盒（要访问用户任意工作副本），
  也不加载第三方代码到自身地址空间（`svn` 是子进程，且包内 dylib 与我们同签名），
  所以不需要 disable-library-validation 之类的例外。把文件留着是为了让「以后要加例外」
  变成一次可评审的 diff，而不是命令行上的一个开关。
- `scripts/sign-macos-app.sh` 由内向外签名（dylib → svn/svnadmin → app），
  每个嵌套二进制都带 `--options runtime`。`--deep` 不用于签名：父级先签会导致签名
  覆盖到后来变化的字节，在 Apple Silicon 上表现为启动即 SIGKILL。开发证书缺时间戳时
  只对开发证书回退 `--timestamp=none`，Developer ID 绝不做此回退。
- **签名会改变二进制字节**，所以 `runtime-manifest.json` 的哈希必须在签名后重算；
  而 manifest 本身又被 app 签名覆盖，所以重算只能发生在**签署 app 之前**。
  `bundle-svn-runtime.sh --refresh-manifest` 由签名脚本调用，manifest 格式只由该脚本写。
- `packaging/macos/notarize.sh`：`notarytool submit --wait` → 失败时取 `notarytool log`
  → `stapler staple` → `stapler validate` → `spctl --assess`。凭据只能来自 keychain
  profile 或环境变量，不读仓库内文件。
- `verify-release.py` 新增 `--require-signed`（Developer ID + hardened runtime）与
  `--require-notarized`（票已装订 + Gatekeeper 放行）。CI 上还测了三条**拒绝路径**：
  无身份时签名脚本必须失败、非 Developer ID 时公证脚本必须失败、ad-hoc 包必须过不了
  `--require-signed`。一个在缺凭据时静默成功的脚本，就是未签名包流进发布的路径。

仍未完成：真实公证。需要 Apple Developer Program 的 Developer ID 证书与 app-specific
password（见下方未决项 1）。

### 未决项（阻塞 Gate A 的剩余部分）

| # | 未决项 | 影响 | 建议动作 |
|---|---|---|---|
| 1 | 缺少 **Developer ID Application** 证书（本机仅有 2 张 Apple Development），且 `notarytool` 无凭据 | 阶段 6 的发行签名、公证、Gatekeeper 验证**无法在本机完成**，只能验证到「签名 + 清单刷新」这一层 | 流水线与拒绝路径已就绪（见上）；确认是否加入 Apple Developer Program，拿到证书后只需注入 6 个 CI secret 并跑一次 tag |
| 2 | 内置运行时的**构建来源**未定：直接用 Homebrew 预编译闭包，还是自建 svn | 前者带 LGPL gettext、仅 arm64、依赖 Cellar 布局；后者可 `--disable-nls`、可出通用二进制、可控 | 建议自建：一次配置换来合规简化 + arm64/x64 双架构 |
| 3 | Intel x86_64 与通用二进制策略 | 规范列为首期 arm64、后续 x64 | 若自建，建议直接产出 universal2，避免二次打包 |
| 4 | Windows 侧完全未验证 | 阶段 6 的 Windows 打包仍是空白 | 需在 Windows 环境跑同等级摸底（依赖收集方式完全不同） |
| 5 | 内置 svn 的**更新责任**：svn 安全更新需随应用发版 | 安全响应周期 | 在 `CHANGELOG` 与发布流程中明确「随应用版本更新」 |

## 后果

- **正向**：S0-3 的 macOS 侧从「未知」变为「已验证，11 MB，路径清晰」。K1 的一半风险消除。
- **负向**：应用包体积 +11 MB；引入 22 个第三方二进制的许可证与安全更新责任。
- **对 CI 的影响**：`macos-ci.yml` 需要多一个「打包并校验运行时」的作业，且该作业在 PR 阶段就应运行
  —— 否则运行时的路径改写与签名问题会拖到发版才暴露。
