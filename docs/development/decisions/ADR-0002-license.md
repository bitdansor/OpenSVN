# ADR-0002: 许可证与第三方合规

> 状态：**已采纳**
> 日期：2026-10-18
> 关联：规划 §10.7、执行计划 S0-2、`NOTICE`、`third_party/README.md`

## 背景

项目自身代码用 Apache-2.0 是规划里的初步建议。真正的约束来自打包进来的 **SVN 运行时**：它把一批 Apache/BSD/MIT 组件带进来，其中一个（`libintl`，来自 gettext）是 GPL/LGPL 双许可。许可证选择不是"选一个文本放进仓库"，而是"决定发布包里能出现什么"。

## 决定

1. 项目代码采用 **Apache-2.0**（`LICENSE` 全文），专利授权与贡献条款由 §5 提供，不需要单独的 CLA。
2. 第三方组件清单落在 `third_party/README.md`，义务摘要落在 `NOTICE`。两者必须在同一 PR 内同步修改——`scripts/verify-release.py --bundle` 会检查打包产物里是否存在 `Contents/Resources/licenses/`，缺了就判失败。
3. **允许**的许可证：Apache-2.0、MIT、BSD-2/3、ISC、Zlib。
4. **条件允许**：LGPL，仅限动态链接、可替换的库，且 PR 必须书面说明如何重链接。
5. **禁止**：任何 GPL/AGPL 进入发布闭包。这条直接指向 `libintl`：
   - 首选修法：自建 svn 运行时加 `--disable-nls`，彻底去掉 gettext 依赖（OpenSVN 的界面不显示 svn 自己的消息目录，得不偿失的能力）。
   - 在该修法完成前，**带 `libintl` 的包不得公开发布**；本机 ad-hoc 构建不受限。
6. 不引入会让应用联网上报、内嵌浏览器引擎、或改变凭据处理方式的依赖，无论其许可证。

## 为什么不用 MIT

Apache-2.0 的专利授权与"不得暗示背书"条款对这个项目更合适：它要与 Apache Subversion 生态共存，需要明确"我们不是 ASF 项目"。MIT 不提供专利条款，反而要另写一份 NOTICE 表达同样意思。

## 如果改变，影响哪些阶段

| 阶段 | 影响 |
| --- | --- |
| 阶段 1–5 | 无（依赖尚未进入发布闭包） |
| 阶段 6 | 打包脚本必须产出 `licenses/`；`--disable-nls` 的 svn 构建要先落地 |
| 阶段 7 | 开源合规审查（规划 §10.7）以本 ADR 为基准 |
