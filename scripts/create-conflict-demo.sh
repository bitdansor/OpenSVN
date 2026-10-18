#!/usr/bin/env bash
# Generates the "try a three-way merge" sample: a local repository plus a working
# copy that already contains conflicts, with a deliberate mix of
#   - three text conflicts that need a decision,
#   - regions that merge automatically (only one side changed them),
#   - one file only the server changed (already updated, no conflict),
#   - one property conflict that *cannot* be three-way merged.
#
#   scripts/create-conflict-demo.sh                   # ~/Documents/OpenSVN 合并演示
#   scripts/create-conflict-demo.sh --path /tmp/demo  # elsewhere
#
# The sample content lives in OpenSVNCore (`DemoWorkspace`), so the in-app
# "试一次三方合并" button and this script cannot drift apart. This script builds
# the development probe and forwards to it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --path) TARGET="${2:?--path needs a value}"; shift 2 ;;
        -h|--help)
            /usr/bin/sed -n '2,14p' "${BASH_SOURCE[0]}" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

ARGS=(demo)
[[ -n "$TARGET" ]] && ARGS+=(--path "$TARGET")

PROBE="$ROOT/apps/macos/.build/debug/opensvn-probe"
if [[ ! -x "$PROBE" ]]; then
    echo "== 正在编译开发工具（首次运行需要一点时间）"
    swift build --package-path "$ROOT/apps/macos" --product opensvn-probe --disable-sandbox >/dev/null
fi

OUTPUT="$("$PROBE" "${ARGS[@]}")"
WORKING_COPY="$(printf '%s\n' "$OUTPUT" | /usr/bin/sed -n 's/^working_copy=//p')"

cat <<EOF

== 演示已生成
   工作副本：$WORKING_COPY

接下来（大约 1 分钟）：

  1. 打开 OpenSVN
     $( [[ -d "$ROOT/build/OpenSVN.app" ]] && echo "open \"$ROOT/build/OpenSVN.app\"" || echo "（从 Xcode 或 swift run 启动）")

  2. 点「添加工作副本…」，选择上面这个目录
     （如果 OpenSVN 已经开着，也可以直接把目录拖进窗口）

  3. 切到「变更」标签页。顶部会出现一条橙色引导条：
     「4 个文件有冲突，其中 3 个可以三方合并」
     点「开始三方合并」。

  4. 在合并编辑器里：
     左栏 = 我的改动，中栏 = 双方共同的基线，右栏 = 服务器上的改动。
     只有两边改了同一处才需要选择；其余区域已经自动合并好了。
     每处选一边，然后点「写入并标记已解决」。

  5. 回到「变更」页，冲突消失，可以正常提交。

说明：docs/属性冲突.txt 是属性冲突，三方合并处理不了，
      需要在右键菜单「解决冲突」里整体选一边 —— 这正是引导条要区分的情况。

整个文件夹可以随时删除，不会影响其他内容。
EOF
