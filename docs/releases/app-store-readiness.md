# App Store 上架就绪评估

> 状态：评估完成，**路线不采用**
> 日期：2026-10-20（评估）/ 2026-10-20（决定不走该路线）
> 结论摘要：当前构建**不可能**通过 Mac App Store 审核。不是缺一个图标或
> 一个字段，而是三条既有架构决策与 App Store 的硬性要求直接冲突。

**决定：OpenSVN 不通过 Mac App Store 分发。** 这份文档因此不是待办清单，而是
「为什么不做」的记录：以后有人问「为什么不上架」，答案在这里，不必重新评估一遍。
下面的 B1–B3 不会开工，除非这条决定本身被推翻。

分发方式仍为 **Developer ID 直发**（见 `packaging/macos/README.md`）。这意味着
签名与公证依然是交付前提——没有公证的 `.app` 从网络下载后会被 Gatekeeper 拦下，
那是分发问题，不是上架问题。

功能层面的欠账在文末单列，两者不要混在一起排期。

---

## 一、结论

Mac App Store 的硬性要求与当前实现的交点有三处，每一处都要改代码：

| 要求 | 现状 | 影响 |
|---|---|---|
| 必须启用 App Sandbox | `packaging/macos/entitlements.plist` **刻意为空**，理由写在文件里：工作副本在任意位置，沙盒会把每次检出变成书签问题 | 架构级：需要安全作用域书签 + 用户授权模型 + 全部路径访问改造 |
| 内置依赖必须可分发 | 打包了 `libintl.8.dylib`（gettext，**GPL-3.0-or-later AND LGPL-2.1-or-later**），且每个 `libsvn_*` 和 `svn`/`svnadmin` 都链着它 | 法务级：GPL 进 App Store 基本无解；LGPL 的「可重链接」要求与 DRM 冲突 |
| 代码必须位于 Apple 允许的目录 | `Contents/Resources/svn/bin/svn` | 需要迁移到 `Contents/Helpers/` 并重新验证签名与发现逻辑 |

还有一项**没有把握的技术未知**，它决定项目能否上架，见第四节。

---

## 二、必须改的代码（Blocking）

### B1. App Sandbox 迁移

- [ ] `packaging/macos/entitlements.plist` 加 `com.apple.security.app-sandbox`
- [ ] 加 `com.apple.security.files.user-selected.read-write`（工作副本读写）
- [ ] 加 `com.apple.security.network.client`（`http(s)://`、`svn://` 仓库）
- [ ] 沙盒下 `~/Library/Logs/OpenSVN`、`Application Support` 会被重定向到容器。
      `AppLog`（`Support/AppLog.swift:71`）与 `OperationJournal`
      （`Services/OperationJournal.swift:108`）的路径需要改为容器内，并在设置页
      如实显示新位置——用户点了「打开日志文件夹」必须真的能打开。
- [ ] `DemoWorkspace.defaultRoot`（`Services/DemoWorkspace.swift:68`）用的是
      `homeDirectoryForCurrentUser`。沙盒下那是容器目录，用户在 Finder 里找不到
      「试一次三方合并」生成的东西。演示改为生成到用户明确选择的目录，或改用
      save panel。

### B2. 安全作用域书签

`RepositoryBookmark`（`Models/RepositoryBookmark.swift`）**只存路径字符串**：

```swift
public var url: URL { URL(fileURLWithPath: path) }
```

沙盒下这是不够的。`NSOpenPanel` 给出的授权只在本次运行有效，重启后再按路径
访问会被拒。需要：

- [ ] 书签模型改为 `URL.bookmarkData(options: .withSecurityScope, ...)`
- [ ] 选中仓库、启动恢复、`startAccessingSecurityScopedResource()` /
      `stopAccessing...` 成对管理（打开时持有，关闭仓库时释放）
- [ ] 书签失效（`isStale`）时提示用户重新选择，而不是静默失败
- [ ] `RepositoryBookmark` 的 `Codable` 兼容旧数据：老用户存的是路径，升级后
      需要一次迁移（重新授权）。这个失败必须可解释，否则用户会以为仓库丢了。

### B3. 内置运行时换位置

- [ ] `Contents/Resources/svn/` → `Contents/Helpers/svn/`
- [ ] `SVNService.bundledCandidateURLs` 与 `SVNDiscovery` 的候选路径同步改
- [ ] `bundle-svn-runtime.sh` 的重签顺序（由内向外）在新路径下重跑
- [ ] `verify-clean-install.sh`、`verify-release.py` 的断言路径同步改
- [ ] 实测 `codesign --verify --deep --strict` 与 App Store Connect 的包校验都能过

### B4. 去掉 gettext

内置的 24 个文件里，`libintl.8.dylib` 来自 `gettext`。`otool -L` 显示它被
**全部 15 个 `libsvn_*` 以及 `svn`、`svnadmin` 依赖**。

- [ ] 从源码构建 Subversion，`--disable-nls`，不链 `libintl`
      （同时可去掉 `libunistring`）
- [ ] `third_party/` 与 `runtime-manifest.json` 随之更新
- [ ] 补 Apache-2.0 的 `NOTICE`：Subversion、APR、APR-util、Serf

这条不做，上架就是带着 GPL-3.0 库提交审核。即使 Apple 不查，这也是本项目的
许可证违约——项目自己是 Apache-2.0。

### B5. 商店资产

- [ ] **应用图标**：目前完全没有（无 `Assets.xcassets`、无 `.icns`、
      `Info.plist` 无 `CFBundleIconFile`）。需要 1024×1024 主图与全尺寸切图。
- [ ] **`PrivacyInfo.xcprivacy`**：无可选填项会直接被拒。需要声明
      `NSPrivacyAccessedAPITypes`（至少 `UserDefaults` → `CA92.1`；如有读取文件
      时间戳 → `C617.1`）与 `NSPrivacyCollectedDataTypes`（本应用不收集数据，
      声明为空，这是卖点，应写清）。
- [ ] `Info.plist`：`CFBundleShortVersionString` 提到 `1.0.0`（商店不接受
      `0.x` 作为首次发布的心理门槛，但技术上可接受，建议 1.0）。

---

## 三、流水线改造

现有 `scripts/sign-macos-app.sh` 是 Developer ID 路线（`--options runtime`）。
App Store 是另一条路，不能复用：

| 项 | Developer ID（现状） | Mac App Store（需要） |
|---|---|---|
| 证书 | `Developer ID Application` | `Apple Distribution`（或 `3rd Party Mac Developer Application`） |
| Entitlements | 空 | `app-sandbox` + 沙盒能力 + `application-identifier` + `team-identifier` |
| 描述文件 | 无 | `Contents/embedded.provisionprofile` |
| 加固运行时 | 必须 | 不需要（与沙盒并行也可） |
| 公证 | `notarytool` + `stapler` | **不需要**，Apple 自己签 |
| 产物 | `.dmg` / `.zip` | `.pkg`（`productbuild --sign "3rd Party Mac Developer Installer"`） |
| 上传 | GitHub Release | `Transporter` / `xcrun altool` → App Store Connect |

- [ ] 新增 `packaging/macos/appstore.sh`：archive → 注入描述文件 → 逐层签名 →
      `productbuild` → 校验
- [ ] `release.yml` 增加 `appstore` 作业，凭据用 5 个 secret
      （证书 p12、p12 密码、描述文件、ASC API Key ID、Issuer ID）
- [ ] `verify-release.py` 增加 `--appstore` 模式：断言沙盒 entitlement 存在、
      描述文件存在、`codesign -d --entitlements` 含 `application-identifier`、
      无 `getent*`/`libintl`、图标存在、隐私清单存在

**注意**：`release.yml` 现有的「拒绝发布未签名产物」闸门要保留，MAS 走独立
分支，两条路不能互相放宽。

---

## 四、决定成败的技术未知（必须先做验证）

**沙盒进程把安全作用域授权传给子进程 `svn` 吗？**

我们的架构是「SwiftUI 应用 → `Process` → 内置 `svn` CLI」。沙盒下：

1. 用户通过 `NSOpenPanel` 选中工作副本 → 应用拿到安全作用域授权
2. 应用 `startAccessingSecurityScopedResource()`
3. 应用 `fork/exec` 内置 `svn`
4. `svn` 要能在该目录读 `.svn/`、写文件、建锁

第 4 步是否成立，取决于沙盒扩展是否被子进程继承。Apple 文档对此表述含糊，
社区经验也不一致，**不能靠读文档定论**。

- 若成立：按第二节改造即可，工作量约 1–2 周
- 若不成立：可选方案是让 `svn` 走文件描述符/临时目录中转，但那会毁掉工作副本
  语义（`.svn` 必须原地写）；**结论就是放弃 App Store，只走 Developer ID 直接分发**

验证方式（1–2 天）：

```
最小 SwiftUI 原型（沙盒 + app-sandbox + user-selected.read-write）
  → NSOpenPanel 选一个目录，存安全作用域书签
  → 重启应用，从书签恢复并 startAccessing
  → Process 执行内置 svn status --xml
  → 再执行 svn commit（写操作）
断言：读能过、写能过、重启后仍能过
```

这个原型不写进主工程，放 `spike/sandbox-probe/`，结论写回本文件。

---

## 五、商店审核与合规（非代码）

- [ ] **加密出口合规**：内置 OpenSSL 3。App Store Connect 会问是否使用加密，
      需要「mass market」豁免说明或自分类报告。这不是勾选框，是要留档的。
- [ ] **中国大陆区上架**：需要 ICP 备案号（2023 年起强制）。若不打算上中国区，
      在 App Store Connect 里取消该地区即可，但中文界面的产品不上中国区很奇怪。
- [ ] **隐私政策 URL、支持 URL**：审核必填，现在没有页面可指。
- [ ] 名称 `OpenSVN` 的商标复核（S7-5）——上架前必须做完，改名的成本在商店里
      比在代码里高得多。
- [ ] 审核说明：需要向审核员解释「这是一个 SVN 客户端，需要用户自备仓库地址」，
      并提供测试账号或一个可用的公开仓库。

---

## 六、功能层面尚未完成（与上架正交）

这些不影响过审，但影响「上架后能不能打」：

| 项 | 现状 |
|---|---|
| F5 认证失败端到端 | 错误映射有测试，完整链路（密码错→只弹一次→丢弃旧凭据）未自动化 |
| F9 杀应用进程 | journal 与工作副本侧通过，「提交到一半杀掉再启」未验证 |
| F13 双窗口写串行 | 只有写锁单元测试，无实机验证 |
| S5-6 脱敏审计报告 | `LogRedactor` 有测试，无独立审计报告 |
| S4-10 两端一致性 | 只有 macOS，随 Windows 推迟 |
| 阶段 6 剩余 | S6-2 真实公证（需 Developer ID）、S6-3 Windows、S6-7 dmg 命名 |
| 阶段 7 | S7-1 交叉回归、S7-2 合规审计、S7-3 用户文档、S7-4 发布说明、S7-5 商标、S7-6 正式发布 |
| P1/P2（规划内标注「后续」） | Repository Browser、Branch/Tag、Lock/Unlock、分支合并向导、自动更新、多语言 |

**自动更新要划掉**：App Store 版本必须用商店更新，Sparkle 一类的自更新会被拒。
如果两条分发渠道并存，自更新逻辑必须按渠道编译隔离。

---

## 七、建议顺序

1. **沙盒可行性验证（第四节）** —— 1–2 天。不通过就没有后面。
2. **B4 去 gettext** —— 与上架无关也该做，属于许可证违约；1 天。
3. **B1/B2/B3 沙盒改造** —— 1–2 周，最大的一块。
4. **B5 商店资产 + 第三节流水线** —— 3–5 天。
5. **第五节合规材料** —— 与代码并行，但 ICP 备案周期不短，越早启动越好。

第 1 步的结论出来之前，不要动第 3 步的任何代码。
