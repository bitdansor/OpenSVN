# F9 — 提交被强制中断（SIGKILL）

## 触发

`svn commit` 正在执行时进程被 `kill -9`。为了让中断落在**提交过程中**而不是提交
前后，仓库装了一个 `pre-commit` hook：它先写一个标记文件、再 `sleep`。harness 等到标记
文件出现（说明事务已开始、hook 正在跑）才杀客户端，因此中断位置是确定的，不靠计时。

```
svn commit  →
  pre-commit hook 开始 → 写 marker → sleep
  ← harness 看到 marker，kill -9 客户端（以及 hook 子进程）
```

## 用户应该看到什么

- **第一次重试提交时**工作副本报「被锁定 / 上次操作未完成」，应用给出 `SVN-0004`，
  下一步是 **Cleanup**（此时 Cleanup 确实是可行的下一步，与 F11 的只读磁盘不同）。
- 应用在下次启动时还会显示一条「上次有 N 项操作没有正常结束」的横幅，其中的提交行
  明确说「可能已经到达服务器，也可能没有。先刷新状态确认，不要直接重复提交。」

注意 `svn status` 本身**不会**因为这次中断而失败：它退出 0，把工作副本标记成 `L`
（第三列）。锁挡住的是写操作，不是读操作 —— 断言必须按这个真实行为写，否则场景会
在第一步就误报。

## 数据状态应该是什么

- 工作副本里的本地修改**一条都不丢**。
- 仓库 HEAD 不变 —— hook 阶段被杀，事务没有提交。
- `svn cleanup` 能清掉残留锁，之后 `svn commit` 能成功、HEAD 前进一个版本。

## 自动化覆盖到哪一层

本场景自动化的是**进程被杀之后工作副本与仓库的真实状态**，以及应用对这一状态的归类。
横幅本身是 GUI，端到端需要杀掉应用进程；那一半由 `OperationJournal` 的单元测试覆盖
（`an in-flight write is visible in the journal until the process returns`、
`an entry written by one run is visible to the next`），日志写在
`~/Library/Application Support/OpenSVN/journal.json`。

## 断言清单

| 断言 | 手段 |
|---|---|
| 中断确实发生在提交过程中 | hook 的 marker 文件存在 |
| 客户端是被杀的 | 退出码 137（128+SIGKILL） |
| 工作副本因此被标记为锁定 | `svn status` 仍是可解析的 XML，且文本输出第三列出现 `L` |
| 写操作被拒绝并归类为 `SVN-0004` | 再次 `svn commit` 报 `E155004` + `opensvn-probe` |
| 提示指向 Cleanup | `remediation` 含 `Cleanup` |
| 锁是可以清的 | `svn cleanup` 退出 0 |
| 本地修改没丢 | 文件内容 + `svn status --xml` 的 `modified` 条目 |
| 提交没有落地 | `svnlook youngest` 不变 |
| 清理后能继续工作 | 再次提交成功且 HEAD +1 |
