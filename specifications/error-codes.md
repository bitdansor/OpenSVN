# 错误码映射

> 状态：v0.1（与 `SVNErrorMapper.swift` 一致）
> 关联：执行计划 S2-3、S3-8、S5-5；规划 §10.6

## 1. 分级

| 分级 | 含义 | 界面行为 |
|---|---|---|
| `recoverable` | 可重试或可自动恢复 | 提示 + “重试”按钮，不弹阻断对话框 |
| `needsUserAction` | 需要用户决策（认证、冲突、确认、不是工作副本） | 弹窗/表单，给出明确下一步 |
| `fatal` | 无法继续 | 展示错误码 + 诊断信息 + 复制按钮 |

## 2. 映射表

匹配优先级：**先 SVN 错误 token（`E\d{6}`），再消息文本**。消息文案随版本与语言变化，token 相对稳定。

| 应用码 | 触发条件 | SVN token | 分级 | 用户可见建议 |
|---|---|---|---|---|
| `SVN-0001` svnNotFound | 探测不到可执行文件 / 无法启动 | — | fatal | 在设置中指定 svn 路径或安装运行时 |
| `SVN-0002` unsupportedVersion | 版本不在支持区间 | — | fatal | 升级 OpenSVN 或改用受支持 svn |
| `SVN-0003` notAWorkingCopy | 目标不是工作副本 | `E155007` | needsUserAction | 重新选择工作副本或重新检出 |
| `SVN-0004` workingCopyLocked | 内部锁 / 上次操作未完成 | `E155004`, `E155037` | recoverable | 先执行 Cleanup |
| `SVN-0005` workingCopyNeedsUpgrade | 工作副本格式过旧/过新 | `E155036`, `E195020` | fatal | 不自动升级，改用兼容客户端 |
| `SVN-0101` authenticationRequired | 需要凭据 | `E215004` | needsUserAction | 输入用户名密码，重试一次 |
| `SVN-0102` authorizationFailed | 凭据被拒绝 | `E170001` | needsUserAction | 检查账号与权限 |
| `SVN-0103` hostKeyVerificationFailed | SSH 主机密钥不受信 | `E170008`, `E170011` | needsUserAction | 核对指纹后再连接 |
| `SVN-0201` networkFailure | 连接失败/超时/代理 | `E170013`, `E175002`, `E175012`, `E210002`, `E670002`, `E000111` | recoverable | 检查网络与仓库地址 |
| `SVN-0202` outOfDate | 需要先 update | `E160028`, `E155011` | recoverable | 先 Update 再提交 |
| `SVN-0301` conflictRemains | 仍有冲突 | `E155015` | needsUserAction | 解决冲突并 resolve |
| `SVN-0302` pathNotFound | 路径不存在 | `E160013` | fatal | 刷新后重试 |
| `SVN-0401` timeout | 超时 | — | fatal | 重试或调整超时 |
| `SVN-0402` cancelled | 用户取消 | — | fatal | 必要时 Cleanup |
| `SVN-0501` confirmationRequired | 危险操作未确认 | — | needsUserAction | 查看预览后确认 |
| `SVN-9001` invalidInvocation | 参数校验失败（空提交说明、目标非空等） | — | fatal | 按提示修正 |
| `SVN-9002` xmlParseFailure | XML 无法解析 | — | fatal | 可能 svn 版本不兼容，附日志反馈 |
| `SVN-9999` commandFailed | 未分类的非零退出 | 其它 | fatal | 展示退出码与诊断 |
| `SVN-9998` unknown | 非 SVNError | — | fatal | 展示原始描述 |

## 3. 文本兜底（无 token 时）

`authorization failed`、`authentication failed`、`could not authenticate`、`no more credentials`、`is not a working copy`、`run 'svn cleanup'`、`previous operation has not finished`、`remains in conflict`、`one or more conflicts remain`、`out of date`、`unable to connect`、`connection refused`、`connection timed out`、`host key verification failed`、`unsupported working copy format`、`too old`。

为避免误判，文本兜底只在没有任何 `E` token 命中时使用。

## 4. 脱敏规则

`diagnosticOutput` 在离开核心层前必须经过脱敏：

- `scheme://user:password@host` → `scheme://***@host`
- `--password <value>` / `--password=<value>` → `***`
- `password|passwd|passphrase|token|secret|api_key=<value>` → `***`
- `Authorization: Basic|Bearer|Digest <value>` → `***`
- 已知密码值的字面替换（双保险）

错误对象不包含 stdin 内容、不包含完整命令行的密码片段。

## 5. 不可重试原则

认证失败**不得**自动循环重试。最多一次显式重试（用户提供新凭据后）。`E155004` 也不得自动 cleanup 后重试，因为清理属于写操作，必须由用户可见地发起。
