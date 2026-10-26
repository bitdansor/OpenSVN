#!/usr/bin/env bash
#
# spike-bundle-svn-macos.sh — 把系统/Homebrew 的 svn 可执行文件及其动态库依赖
# 打包进一个 .app 包内，改写为 @rpath 相对引用，并做 ad-hoc 签名，产出可独立运行的副本。
#
# 用途：验证「内置 SVN 运行时」策略在 macOS 上的可行性。
#      这是 S0-3 的技术摸底工具，不是最终发布流水线的一部分。
#
# 用法：
#   ./spike-bundle-svn-macos.sh [-s /path/to/svn] [-o /path/to/out.app]
#
# 退出码：0 全部通过；1 参数或环境错误；2 打包后校验失败
#
set -euo pipefail

SVN_BIN="$(command -v svn || true)"
OUT_APP="/tmp/OpenSVN-spike/OpenSVN.app"

while getopts "s:o:h" opt; do
  case "$opt" in
    s) SVN_BIN="$OPTARG" ;;
    o) OUT_APP="$OPTARG" ;;
    h) sed -n '2,16p' "$0"; exit 0 ;;
    *) exit 1 ;;
  esac
done

[ -n "$SVN_BIN" ] && [ -x "$SVN_BIN" ] || { echo "错误：找不到可执行的 svn，用 -s 指定" >&2; exit 1; }
command -v otool >/dev/null || { echo "错误：缺少 otool（需安装 Xcode 命令行工具）" >&2; exit 1; }
command -v install_name_tool >/dev/null || { echo "错误：缺少 install_name_tool" >&2; exit 1; }
command -v codesign >/dev/null || { echo "错误：缺少 codesign" >&2; exit 1; }

MACOS_DIR="$OUT_APP/Contents/MacOS"
FW_DIR="$OUT_APP/Contents/Frameworks"

echo "==> 源 svn: $SVN_BIN"
"$SVN_BIN" --version --quiet 2>/dev/null | sed 's/^/    版本: /'

rm -rf "$OUT_APP"
mkdir -p "$MACOS_DIR" "$FW_DIR"
cp "$SVN_BIN" "$MACOS_DIR/svn"
chmod u+w "$MACOS_DIR/svn"

# 列出某个 Mach-O 依赖的非系统 dylib（绝对路径且不在 /usr/lib、/System）
list_third_party_deps() {
  otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' | \
    grep -E '^/' | grep -vE '^/(usr/lib|System)/' || true
}

# 广度优先收集闭包，按「原始引用路径 -> 包内文件名」建立映射
echo "==> 收集依赖闭包"
declare -a QUEUE=("$SVN_BIN")
declare -a SEEN=()
declare -a MAP_FROM=()
declare -a MAP_TO=()
INDEX=0

while [ "$INDEX" -lt "${#QUEUE[@]}" ]; do
  CUR="${QUEUE[$INDEX]}"; INDEX=$((INDEX + 1))
  while IFS= read -r DEP; do
    [ -z "$DEP" ] && continue
    # 已处理过该引用路径则跳过
    ALREADY=0
    for F in "${MAP_FROM[@]:-}"; do [ "$F" = "$DEP" ] && ALREADY=1 && break; done
    [ "$ALREADY" -eq 1 ] && continue
    REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$DEP" 2>/dev/null || echo "$DEP")"
    [ -f "$REAL" ] || { echo "    警告：依赖不存在，跳过 $DEP" >&2; continue; }
    NAME="$(basename "$DEP")"
    cp "$REAL" "$FW_DIR/$NAME"
    chmod u+w "$FW_DIR/$NAME"
    MAP_FROM+=("$DEP"); MAP_TO+=("$NAME")
    QUEUE+=("$REAL")
  done < <(list_third_party_deps "$CUR")
done

echo "    打包 dylib: $(ls -1 "$FW_DIR" | wc -l | tr -d ' ') 个（去重后）"

# 改写：二进制与每个 dylib 的依赖路径 -> @rpath/<name>；dylib 自身 id 也改为 @rpath
echo "==> 改写 install name"
for TARGET in "$MACOS_DIR/svn" "$FW_DIR"/*.dylib; do
  while IFS= read -r DEP; do
    [ -z "$DEP" ] && continue
    for i in "${!MAP_FROM[@]}"; do
      if [ "${MAP_FROM[$i]}" = "$DEP" ]; then
        install_name_tool -change "$DEP" "@rpath/${MAP_TO[$i]}" "$TARGET" 2>/dev/null || true
        break
      fi
    done
  done < <(list_third_party_deps "$TARGET")

  case "$TARGET" in
    *Frameworks*) install_name_tool -id "@rpath/$(basename "$TARGET")" "$TARGET" 2>/dev/null || true ;;
  esac
done

# 主程序注入 rpath（若已存在则忽略报错）
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/svn" 2>/dev/null || true

# 生成最小 Info.plist，使 .app 成为结构合法的 bundle（正式版由 Xcode 生成）
cat > "$OUT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.opensvn.spike</string>
  <key>CFBundleName</key><string>OpenSVN</string>
  <key>CFBundleExecutable</key><string>svn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.0-spike</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

# 签名：先内层 dylib，再主程序，最后整个 bundle（顺序不能反，否则外层签名失效）
# 注意：Apple Silicon 上 install_name_tool 会破坏原签名，必须重签，否则被内核 SIGKILL
echo "==> ad-hoc 签名（内层优先）"
for f in "$FW_DIR"/*.dylib; do codesign --force --sign - "$f" >/dev/null 2>&1; done
codesign --force --sign - "$MACOS_DIR/svn" >/dev/null 2>&1
codesign --force --sign - "$OUT_APP" >/dev/null 2>&1 || true

# ---- 校验 ----
echo "==> 校验"
FAIL=0

RESIDUE="$(otool -L "$MACOS_DIR/svn" | grep -E '^\s+/(opt|usr/local)/' || true)"
for f in "$FW_DIR"/*.dylib; do
  R="$(otool -L "$f" | grep -E '^\s+/(opt|usr/local)/' || true)"
  [ -n "$R" ] && RESIDUE="$RESIDUE$R"$'\n'
done
if [ -n "${RESIDUE// /}" ] && [ -n "$(echo "$RESIDUE" | tr -d '[:space:]')" ]; then
  echo "    ✗ 仍存在宿主绝对路径依赖：" >&2
  echo "$RESIDUE" >&2
  FAIL=1
else
  echo "    ✓ 无宿主绝对路径残留"
fi

codesign --verify --strict "$OUT_APP" >/dev/null 2>&1 \
  && echo "    ✓ bundle 签名校验通过" \
  || { echo "    ✗ bundle 签名校验失败" >&2; FAIL=1; }

codesign --verify --deep --strict "$OUT_APP" >/dev/null 2>&1 \
  && echo "    ✓ 嵌套代码（dylib）签名校验通过" \
  || { echo "    ✗ 嵌套代码签名校验失败" >&2; FAIL=1; }

if VER="$("$MACOS_DIR/svn" --version --quiet 2>&1)"; then
  echo "    ✓ 独立运行成功（svn ${VER}）"
else
  echo "    ✗ 无法运行：${VER}" >&2; FAIL=1
fi

echo "    包体积: $(du -sh "$OUT_APP" | awk '{print $1}')"
echo "    产物路径: $OUT_APP"

[ "$FAIL" -eq 0 ] || exit 2
echo "==> 通过"
