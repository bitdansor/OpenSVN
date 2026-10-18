# F11 — 工作副本所在磁盘不可写

## 触发

工作副本的 `.svn` 目录被设为只读（模拟只读卷、被系统保护、权限被改），然后提交。

```
chmod -R a-w wc/.svn
svn commit →
```

注意触发点必须是 `.svn`，不是文件本身：只把受版本控制的文件设成只读，`svn commit`
照样成功——提交只需要**读**工作文件、**写** `.svn`。把文件设成只读是另一回事
（那是 `svn` 不需要写的时候），不能用来模拟磁盘只读。

## 用户应该看到什么

- 失败，归类为 `SVN-0006`：「工作副本目录或磁盘不可写。请检查文件权限、只读卷或磁盘
  空间；Cleanup 无法解决只读磁盘。」
- **不能**归类为 `SVN-0004`（工作副本被锁定）并提示「先执行 Cleanup」——Cleanup 要写
  的正是那块拒绝了提交的磁盘，用户会照着提示再失败一次。

## 数据状态应该是什么

- 本地修改完整保留。
- 仓库 HEAD 不变。
- 权限恢复后工作副本立刻可正常读取（`svn status --xml` 可解析），不需要任何修复动作。

## 这个场景抓到的真实缺陷

svn 的实际输出顺序是：

```
svn: E155004: Run 'svn cleanup' to remove locks …
svn: E155004: Failed to lock working copy '/…/wc'.
svn: E200031: sqlite[S8]: attempt to write a readonly database
```

`E155004` 先出现，而映射表里 `E155004 → workingCopyLocked` 排在前面，于是应用把
「磁盘不可写」讲成了「工作副本被锁」。修法是把 `E200031` 等权限 token 排在 `E155004`
之前——表内顺序即匹配顺序。`specifications/error-codes.md` 记录了这条规则。

## 断言清单

| 断言 | 手段 |
|---|---|
| 提交失败 | `svn commit` 退出码非 0 |
| 真实原因是权限 | stderr 含 `E200031` |
| 归类为 `SVN-0006` | `opensvn-probe map-error` |
| 提示不是死路 | `remediation` 含 `Cleanup 无法解决只读磁盘`，且不含 `先执行 Cleanup` |
| 本地修改仍在 | 文件内容 + `svn status --xml` 的 `modified` 条目 |
| 提交没有落地 | `svnlook youngest` 不变 |
| 恢复权限后可直接使用 | 恢复 `u+w` 后 `svn status --xml` 可解析 |
