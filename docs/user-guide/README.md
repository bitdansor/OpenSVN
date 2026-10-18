# User guide

Written for people using OpenSVN, not for people building it. Planned chapters,
in the order a new user needs them:

1. **安装与首次启动** — macOS: 把 `.app` 拖进「应用程序」，首次打开时 Gatekeeper 的处理；Windows: 安装包形态（待 ADR-0005 定稿）。
2. **找到 Subversion** — 设置页里的 `svn` 路径、版本区间、内置运行时的优先级。
3. **检出与打开工作副本** — 两种入口的区别，以及为什么 OpenSVN 不会"导入"一个普通目录。
4. **日常循环** — 改文件 → 看 Changes → Diff → Commit → Update。
5. **冲突** — 三种冲突分别长什么样，`working` / `mine-full` / `theirs-full` 各自会丢掉什么。
6. **出错时怎么办** — 用错误码（`SVN-0004` 等）对照 `specifications/error-codes.md` 的处理建议。
7. **凭据与隐私** — 密码存在哪里、什么时候会被删除、日志里能看到什么。

Screenshots go in `assets/screenshots/`. Do not write chapters for features that
do not exist yet.
