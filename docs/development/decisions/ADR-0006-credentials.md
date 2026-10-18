# ADR-0006：凭据语义

> 状态：**已采纳**
> 日期：2026-10-18
> 关联：执行计划 S0-8 / S3-3 / S3-4 / K4、规范 §6、§10.2
> 影响阶段：阶段 3（服务层）、阶段 5（日志审计）、阶段 6（干净系统测试）

## 问题

“记住密码”这句话背后有六个必须分别回答的问题：存什么、存哪里、什么时候存、什么时候删、失败后怎么办、日志里怎么保证没有。任一项含糊，都会在阶段 5 的审计里变成重构。

## 决策

### 存什么

- 只存 `username + password`，以**主机**为键（`CredentialScope(host:)`）。
- 不存 realm：首个挑战之前无法知道 realm；同一主机多账号的场景按“最后一次成功”覆盖，与 SVN 自身行为一致。
- 不存 URL（URL 可能含 userinfo，存下来等于复制一份风险）。
- `file://` 不产生凭据条目。

### 存哪里

macOS：**Keychain**，`kSecClassGenericPassword`，`service = cn.opensvn.credentials`，`account = <host>`。值是一个 JSON `{username, password}`。

- 不使用 `UserDefaults`、不写入工作副本、不写入日志。
- 钥匙串访问失败（`errSecAuthFailed` 等）映射为 `CredentialStoreError`，不静默当作“没有凭据”。

### 什么时候写

**只在一次成功认证之后写**。首次尝试不带凭据；用户提交后重试成功才落盘。失败的密码绝不覆盖已有条目（避免“改错一次就丢失正确密码”）。

### 什么时候删

1. 使用钥匙串凭据仍然收到 `E170001`（被拒绝）→ 立即删除该主机条目，然后要求重新输入；
2. 用户在设置中“清除全部凭据”；
3. 不因网络错误、超时、服务器 5xx 删除凭据（那会把可恢复故障误判为凭据失效）。

### 失败后怎么办

- 认证失败最多**重试一次**（用户显式提交新凭据后）。
- 不做指数退避自动重试，不做“尝试所有已存凭据”。
- UI 取消后不再弹窗，保留错误提示。

### 怎么保证不进日志

三层：

1. **传输层**：`--password-from-stdin`，密码写在 stdin，一次性关闭；argv 中只有用户名。
2. **日志层**：所有离开核心层的 stderr/命令行先过 `LogRedactor`（URL userinfo、`--password`、`password=`、`Authorization`、已知密码字面量）。
3. **结构层**：`SVNCredential.description` / `debugDescription` 输出 `password: ***`，即使有人误用字符串插值也不会泄漏。

## 已验证 / 未验证

| 项 | 状态 |
|---|---|
| `--password-from-stdin` 在 svn 1.14.5 可用 | 已验证（`svn help commit -v`） |
| 密码不出现在 argv | 代码路径单一（`SVNService.runOnce`），已审阅 |
| Keychain 读写 | 已实现，未在干净系统上做权限/迁移测试（阶段 6 补） |
| `svn+ssh` 认证 | 已透传 `SSH_AUTH_SOCK`，未做端到端测试 |

## 后果

- **正向**：密码只有两个副本（内存瞬时、钥匙串），审计面小；`--no-auth-cache` 避免 svn 在 `~/.subversion/auth` 再存一份。
- **负向**：同一主机多账号需要重复输入；每次认证都要两次进程（首次失败 + 重试），比 svn 自身的 auth cache 慢一点。
- **对 CI 的影响**：集成测试只用 `file://`，不触碰 Keychain；Keychain 相关代码用 `InMemoryCredentialStore` 覆盖逻辑。

## 若改变

改为“保存 realm”或“支持多账号”需要修改 `CredentialScope`、设置页的清除逻辑、以及阶段 5 的日志审计范围。
