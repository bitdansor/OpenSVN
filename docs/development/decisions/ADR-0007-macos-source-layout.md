# ADR-0007: macOS 源码布局（SwiftPM 为主，Xcode 工程并存）

> 状态：**已采纳**
> 日期：2026-10-18
> 关联：`docs/architecture/overview.md`（目录映射表）、`apps/macos/Package.swift`

## 背景

最初的目录树假定 macOS 端是**纯 Xcode 工程**布局：`apps/macos/OpenSVN/{App,Views,Models,Services,...}`、`OpenSVNTests/`、`OpenSVNUITests/`。实际实现用了另一套：

```text
apps/macos/
  Package.swift                    # SwiftPM：OpenSVNCore 库 + OpenSVN 可执行
  Sources/OpenSVNCore/             # 核心层（可被测试单独依赖）
  Sources/OpenSVN/                 # SwiftUI 应用
  Tests/OpenSVNCoreTests/          # Swift Testing
  Resources/Info.plist
  OpenSVN.xcodeproj/               # 引用本地包，用官方模板的 Xcode 外壳
```

## 决定

1. **以 SwiftPM 为唯一事实来源**：`swift build` / `swift test` 能完成全部编译与测试，不需要 Xcode。
2. **Xcode 工程保留但极薄**：通过 `XCLocalSwiftPackageReference` 引用本地包，只负责打包成 `.app`、提供调试与签名入口。`project.pbxproj` 使用 `PBXFileSystemSynchronizedRootGroup`（objectVersion 77），不手工维护文件清单。
3. **核心层独立成 target**：`OpenSVNCore` 不含任何 SwiftUI 依赖，测试只依赖它。这直接支撑了"无界面即可验证契约"这条要求。
4. 目录改名：`Sources/OpenSVNCore/` 对应最初设计中的 `Services/` + `Models/`；`Tests/OpenSVNCoreTests/` 对应 `OpenSVNTests/`。**映射关系记录在 `docs/architecture/overview.md`**，不为了对齐目录树而把代码拆开。

## 理由

- 最初的目录树只写着"逐步形成的目标结构，初始化时不需要手工创建所有空文件"，它是**意图描述**而非签名契约。把核心层拆成独立 target 是执行过程中得到的更强结构。
- CI 里 `xcodebuild` 需要完整 Xcode 与签名配置，`swift test` 不需要。核心契约测试应该在最低门槛下可跑。
- 手工维护 `.pbxproj` 文件清单是长期痛苦的来源（合并冲突、漏加文件导致"编译通过但运行崩溃"），同步根组消除了这类问题。

## 代价（必须承认）

1. 与最初的目录树不一致，新人第一眼会困惑 → 用 `docs/architecture/overview.md` 的映射表缓解。
2. Xcode 工程仍然存在两份"工程描述"（`Package.swift` 与 `.pbxproj`），新增 target 时要改两处。
3. SwiftPM 的可执行 target 打成 `.app` 需要 `scripts/build-macos-app.sh` 手工组装 bundle；这一步未来要用 `xcodebuild archive` 替代（阶段 6）。

## 如果改变，影响哪些阶段

| 阶段 | 影响 |
| --- | --- |
| 阶段 1–5 | 无 |
| 阶段 6 | 若改为纯 Xcode 工程，`build-macos-app.sh` 与 CI 的 `swift test` 步骤都要重写 |
| 阶段 7 | 用户文档里的构建说明 | 

## 与 Windows 侧的一致性

Windows 端尚未开始（`apps/windows/` 只是空占位）。重做时不必复制本文的结构：两端结构可以不同，**契约一致**才是要求（见 `specifications/`）。
