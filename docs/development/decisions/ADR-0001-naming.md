# ADR-0001: 项目命名

> 状态：**暂定**（可执行，但未完成商标核查）
> 日期：2026-10-18
> 关联：`README.md`、`LICENSE`

## 背景

`OpenSVN` 这个名字要同时满足四件事：GitHub 仓库名可用、没有在先商标造成实质冲突、主要域名可注册（或明确不需要）、社区搜索时不与既有项目混淆。正式公开前需要核对，本文明确记录"尚未确认无冲突"。

## 决定

1. **以 `OpenSVN` 作为工作名称继续开发**，GitHub 组织路径使用仓库内所有文档已引用的 `opensvn`。
2. **不把名称当作已清权**：`README` 中写明 "OpenSVN is not affiliated with the Apache Software Foundation"，并在 `NOTICE` 中保留该声明。
3. 对外发布（`v1.0.0`）前必须完成一次书面核查，把结论补进本 ADR。核查项：
   - GitHub 组织 / 仓库是否已有同名活跃项目；
   - 中国（CNIPA）、美国（USPTO）、欧盟（EUIPO）商标库中 `OpenSVN` 及近似标识；
   - `opensvn.org` / `opensvn.com` / `opensvn.dev` 的归属；
   - 搜索"OpenSVN client"是否已有用户认知度较高的其他产品。
4. 若核查发现实质冲突，改名成本被刻意压低：名称只出现在 `README`、`NOTICE`、bundle identifier（`cn.opensvn.app`）、Credential Manager 条目前缀（`OpenSVN:`）与 Xcode 工程名中。**不要再把名称硬编码进新的存储键或 SQL 类路径**，否则改名会变成数据迁移问题。

## 为什么不是现在就叫停

名称风险影响的是"发布后被迫改名"，不影响"现在能不能写代码"。把它当成发布前检查项，比停下来等核查结论更划算——但风险不能消失，所以它在这里留有明确的状态和终止条件。

## 如果改变，影响哪些阶段

| 阶段 | 影响 |
| --- | --- |
| 阶段 1–5 | 无（名称只在文档与 bundle id） |
| 阶段 6 | 签名证书的 common name、安装包文件名、`Package.appxmanifest` 的 `Publisher`/`Identity` |
| 阶段 7 | 域名、README 徽章、发布说明 |
