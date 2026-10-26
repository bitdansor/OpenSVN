# 兼容性契约

> 状态：v0.1 · 实测环境：macOS 27.0.1 / arm64 / Xcode 27.1 / svn 1.14.5

## 1. SVN CLI 支持区间

| 项目 | 结论 | 依据 |
|---|---|---|
| 最低版本 | **1.10.0** | `--password-from-stdin` 自 1.10 起可用，是“密码不进 argv”红线的唯一实现方式 |
| 最高版本 | `< 2.0.0`（不含） | 1.x 内 XML 结构稳定；2.x 必须重新验证 |
| 首选版本 | 1.14.x | 当前测试与 fixture 采集版本 |
| 打包策略 | 内置运行时（macOS） | 见 `packaging/macos/README.md` |

版本校验在启动时执行 `svn --version --quiet`，解析失败或越界即报 `SVN-0002`，不静默降级。

## 2. 工作副本格式矩阵

| 工作副本格式 | svn 1.10 | svn 1.14 | OpenSVN 行为 |
|---|---|---|---|
| 1.8–1.14 创建 | 可读写 | 可读写 | 正常 |
| 更新版本客户端创建（格式高于当前 svn） | 报 `E155036`/`E195020` | 报错 | 报 `SVN-0005`，**不自动升级** |
| 过旧格式（需 upgrade） | 报错提示 upgrade | 报错 | 报 `SVN-0005`，引导用户显式处理 |

“不自动升级”是硬约束：升级不可逆，且会让用户无法回到旧客户端。

## 3. 平台矩阵

| 平台 | 最低版本 | 架构 | 状态 |
|---|---|---|---|
| macOS | 14.0 | arm64（首期），x86_64 后续 | 已实现 |
| Windows | Windows 11 | x64 | 已实现；运行时待真实 svn 验证 |

macOS 不启用 App Sandbox：需要任意路径的工作副本访问与子进程执行。代价是无法上架 Mac App Store，分发走 Developer ID + 公证（阶段 6）。

Windows 端已实现（C++20 核心 + C# WinUI 3，unpackaged），原生测试通过，但只用
`fake_svn.exe` 做过运行时验证；安装包、内置运行时与真实 `svn.exe` 的兼容性验证尚未完成。
状态与缺口见 `apps/windows/README.md`。

## 4. locale 与编码

**必须固定为 UTF-8 locale**：

```text
LC_ALL=en_US.UTF-8
LANG=en_US.UTF-8
LC_CTYPE=en_US.UTF-8
```

实测结论：设置 `LC_ALL=C` 时，svn 1.14.5 对中文路径报

```text
svn: E000022: Can't convert string from native encoding to 'UTF-8'
```

因此“固定 C locale 以保证解析稳定”的做法是**错误的**。XML 输出的日期/数字本身与 locale 无关，UTF-8 locale 同样稳定，且能正确处理非 ASCII 路径。

## 5. 路径边界

必须支持并通过测试：

- 中文路径（`docs/中文 文档 (v1) & notes.txt`）
- 空格
- 特殊字符 `& ( ) [ ] ' "`
- 长路径（单段 < 255 字节，总长 < 1024 字节的保守范围）
- 大小写敏感卷与不敏感卷（macOS 默认不敏感）

已知限制：

- Windows 端需处理 `MAX_PATH`，必要时使用 `\\?\` 前缀；契约要求两端对同一路径的**相对路径显示**一致。
- 文件名中包含换行符的场景不做保证。

## 6. 服务器与传输

| 传输 | 状态 | 备注 |
|---|---|---|
| `file://` | 已测试 | 集成测试与 fixture 使用 |
| `http(s)://` | 已实现，未做真实服务器测试 | 证书校验默认严格 |
| `svn://` | 已实现，脚本可启动 `svnserve` | `scripts/setup-test-repo.sh --serve` |
| `svn+ssh://` | 已实现 | 透传 `SSH_AUTH_SOCK`；主机密钥失败映射 `SVN-0103` |

自签名证书：当前**不**自动信任。`--trust-server-cert-failures` 只应在用户显式确认后使用，MVP 未开放该开关。

## 7. 版本记录

修改本文时同步更新：

1. `tests/fixtures/README.md` 中记录的 svn 版本；
2. `.github/workflows/macos-ci.yml` 里钉住的工具链基线；
3. 若改变支持区间，`CHANGELOG.md` 必须写明影响。
