# ADR-0005: Windows 安装包形态

> 状态：**暂定**（倾向 MSIX，未在干净系统上实测）
> 日期：2026-10-18
> 关联：`packaging/windows/README.md`、`docs/releases/README.md`
>
> **2026-10-18 注**：ADR 保留，但 `apps/windows/` 已清空、Windows 端尚未开始，
> 本文所有结论都没有对应的可执行物。重做 Windows 端时先复核本文，不要默认它仍然成立。

## 背景

Windows 端有两种现实选择：**MSIX**（现代打包，带身份、可增量更新、卸载干净）与**传统 EXE 安装器**（Inno Setup / WiX）。这不是纯偏好问题，它决定了三件事：

1. `svn.exe` 运行时能不能被写进安装目录并被应用启动；
2. 用户能不能选择任意磁盘位置的工作副本；
3. 签名证书要几种。

## 决定（暂定）

1. **主目标：MSIX（packaged）**，与 WinUI 3 模板一致。上一版骨架曾按此形态写过 `Package.appxmanifest`（已随 `apps/windows/` 一起删除），重做时照此声明。
2. MSIX 的 `runFullTrust` 能力必须声明——应用要启动 `svn.exe` 子进程，这是 packaged app 的已知边界；完整信任不是"提权"，但仍需在发布说明中讲清楚。
3. **不使用 `broadFileSystemAccess`**。工作副本位置由用户通过文件选择器指定，其余路径一律不可见；这样即使清单被误改，应用也拿不到全盘访问。
4. `svn.exe` 以**自包含**方式随包分发（对应 ADR-0003 的 macOS 策略），放在安装目录下由发现逻辑优先使用；系统安装的 svn 只作为回退。
5. **保留退路**：如果实测发现 MSIX 的子进程 / 任意路径访问在某些企业环境不可用，改用 **EXE 安装器 + 自包含运行时**，此时 `Package.appxmanifest` 降级为仅用于开发调试。

## 必须实测才能定稿的三件事

| # | 问题 | 为什么不能靠文档判断 |
| --- | --- | --- |
| W1 | packaged app 启动自带的 `svn.exe` 是否需要额外声明 | 不同 Windows App SDK 版本行为有差异，必须真机复现 |
| W2 | MSIX 包内 `svn.exe` 读取用户工作副本是否受包边界限制 | 与 `runFullTrust` 的实际生效范围有关，文档表述含糊 |
| W3 | 未签名 / 自签名包在干净 Windows 11 上的安装体验 | SmartScreen 的行为随版本变化，必须实测再写进发布说明 |

在 W1–W3 有结论前，**不发布 Windows 安装包**。`release.yml` 的 windows job 因此是关闭状态。

## 签名

- 需要 **EV 代码签名证书**（或 Azure Trusted Signing）才能避免 SmartScreen 警告；普通 OV 证书在 Windows 11 上首次安装仍会提示。
- 证书来源、有效期、私钥保管方式必须在阶段 6 前写入 `docs/releases/`，且私钥不得进入 CI 的普通环境变量（用受保护的 secret + 受限环境）。

## 如果改变，影响哪些阶段

| 阶段 | 影响 |
| --- | --- |
| 阶段 1–5 | 无（工程文件已按 packaged 形态建立） |
| 阶段 6 | 打包脚本、签名流程、发布资产命名（`.msix` vs `.exe`） |
| 阶段 7 | 安装/卸载文档、企业部署说明 |
