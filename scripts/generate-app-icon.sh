#!/usr/bin/env bash
# Generates build/AppIcon.icns from apps/macos/Resources/AppIcon.svg.
#
# Pipeline: source SVG -> 1024x1024 PNG -> .iconset (16/32/128/256/512, each
# 1x and 2x) -> .icns via iconutil. Only tools shipped with macOS (sips,
# iconutil, swiftc) or already installed on the host are used; nothing is
# downloaded and no network access is required.
#
# Toolchain notes
#   sips cannot rasterise SVG. We therefore try, in order: rsvg-convert,
#   inkscape, cairosvg and qlmanage (macOS Quick Look). Each candidate is
#   functionally tested -- it must actually emit a valid 1024x1024 PNG, because
#   qlmanage in particular can fail silently (e.g. "sandbox initialization
#   failed") or produce a padded thumbnail. On a stock Mac none of the first
#   three is present and qlmanage is unreliable, so the script falls back to a
#   small self-contained Swift/CoreGraphics renderer embedded below. It is
#   compiled once with swiftc and cached in build/, then reused on later runs.
#   That guarantees the pipeline always produces a real .icns on this machine
#   instead of leaving a script that can never succeed.
#
# Commit policy
#   AppIcon.svg is the committed source of truth -- the only tracked artwork.
#   build/AppIcon.icns is a reproducible build artifact: build/ is ignored by
#   .gitignore, so the .icns is NOT committed (it is generated, never
#   hand-edited, and never a placeholder). Every build regenerates it. If one
#   ever wants to ship a pre-baked .icns in the tree, it must live outside
#   build/ and be explicitly un-ignored; see packaging/macos/README.md.
#
# Repeatability: safe to run any number of times; each run rebuilds the PNG,
# the iconset and the .icns from scratch. Exit status is non-zero on any real
# failure, with a human-readable "error: ..." message.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT/apps/macos/Resources/AppIcon.svg"
BUILD="$ROOT/build"
ICONSET="$BUILD/AppIcon.iconset"
PNG="$BUILD/AppIcon-1024.png"
ICNS="$BUILD/AppIcon.icns"
RENDER_SRC="$BUILD/AppIconRenderer.swift"
RENDER_BIN="$BUILD/appicon-render"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "info: $*"; }

[[ -f "$SVG" ]] || die "source artwork not found: $SVG"
for tool in sips iconutil swiftc; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found on PATH"
done
mkdir -p "$BUILD"

# Return 0 only if $1 exists and is exactly 1024x1024.
valid_png() {
  local f="$1" dims
  [[ -s "$f" ]] || return 1
  dims="$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null \
    | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')" || return 1
  [[ "$dims" == "1024x1024" ]]
}

# ---------------------------------------------------------------------------
# Renderer candidates. Each leaves a valid 1024x1024 PNG at $PNG on success.
# ---------------------------------------------------------------------------

try_rsvg() {
  command -v rsvg-convert >/dev/null 2>&1 || return 1
  rsvg-convert -w 1024 -h 1024 "$SVG" -o "$PNG" >/dev/null 2>&1 || return 1
  valid_png "$PNG"
}

try_inkscape() {
  command -v inkscape >/dev/null 2>&1 || return 1
  inkscape "$SVG" --export-type=png --export-filename="$PNG" \
    -w 1024 -h 1024 >/dev/null 2>&1 || return 1
  valid_png "$PNG"
}

try_cairosvg() {
  python3 -c 'import cairosvg' >/dev/null 2>&1 || return 1
  python3 - "$SVG" "$PNG" <<'PY' >/dev/null 2>&1 || return 1
import sys, cairosvg
cairosvg.svg2png(url=sys.argv[1], write_to=sys.argv[2],
                 output_width=1024, output_height=1024)
PY
  valid_png "$PNG"
}

try_qlmanage() {
  command -v qlmanage >/dev/null 2>&1 || return 1
  local tmp out
  tmp="$(mktemp -d "$BUILD/.qlrender.XXXXXX")" || return 1
  qlmanage -t -s 1024 -o "$tmp" "$SVG" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  out="$tmp/$(basename "$SVG").png"
  if valid_png "$out"; then
    cp "$out" "$PNG" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

# Deterministic fallback: draw the icon directly with CoreGraphics. The Swift
# source is written only when it changes, so swiftc runs once, not every build.
write_swift_source() {
  local tmp
  # Keep XXXXXX at the very end: BSD/macOS mktemp only substitutes trailing X's.
  tmp="$(mktemp "$BUILD/.AppIconRenderer.XXXXXX")" || return 1
  cat > "$tmp" <<'APPICON_SWIFT_EOF'
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// Mirrors apps/macos/Resources/AppIcon.svg. Keep coordinates and colours in
// sync with that file: this is the deterministic rasteriser used when no SVG
// renderer is available on the host.
let SIZE = 1024
let W = CGFloat(SIZE)
let H = CGFloat(SIZE)

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: appicon-render <output.png>")
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: SIZE, height: SIZE,
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fail("could not create CGContext")
}
// SVG-style coordinates: origin top-left, y grows downward.
ctx.translateBy(x: 0, y: H)
ctx.scaleBy(x: 1, y: -1)
let full = CGRect(x: 0, y: 0, width: W, height: H)

// Diagonal indigo -> blue background.
let bgStops: [(CGFloat, CGColor)] = [
    (0.00, rgba(0.310, 0.490, 0.953)), // #4F7DF3
    (0.55, rgba(0.231, 0.420, 0.870)), // #3B6BDE
    (1.00, rgba(0.106, 0.165, 0.420)), // #1B2A6B
]
let bgGrad = CGGradient(colorsSpace: cs,
                        colors: bgStops.map { $0.1 } as CFArray,
                        locations: bgStops.map { $0.0 })!
ctx.saveGState()
ctx.addRect(full); ctx.clip()
ctx.drawLinearGradient(bgGrad,
                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Soft top-left sheen.
let sheenGrad = CGGradient(colorsSpace: cs,
                           colors: [rgba(1, 1, 1, 0.16), rgba(1, 1, 1, 0.0)] as CFArray,
                           locations: [0.0, 1.0])!
ctx.saveGState()
ctx.addRect(full); ctx.clip()
ctx.drawRadialGradient(sheenGrad,
                       startCenter: CGPoint(x: 300, y: 240), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 240), endRadius: 760,
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Subtle inset frame.
ctx.saveGState()
ctx.setStrokeColor(rgba(1, 1, 1, 0.16))
ctx.setLineWidth(6)
let frame = CGRect(x: 44, y: 44, width: W - 88, height: H - 88)
ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 200, cornerHeight: 200,
                   transform: nil))
ctx.strokePath()
ctx.restoreGState()

// Branch graph: trunk + fork, rounded white strokes.
ctx.saveGState()
ctx.setStrokeColor(rgba(1, 1, 1, 1))
ctx.setLineWidth(40)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let graph = CGMutablePath()
graph.move(to: CGPoint(x: 512, y: 828))
graph.addLine(to: CGPoint(x: 512, y: 470))
graph.move(to: CGPoint(x: 512, y: 470))
graph.addLine(to: CGPoint(x: 296, y: 250))
graph.move(to: CGPoint(x: 512, y: 470))
graph.addLine(to: CGPoint(x: 728, y: 250))
ctx.addPath(graph)
ctx.strokePath()
ctx.restoreGState()

// Commit nodes.
ctx.saveGState()
ctx.setFillColor(rgba(1, 1, 1, 1))
for (x, y) in [(512, 828), (512, 470), (296, 250), (728, 250)] as [(CGFloat, CGFloat)] {
    ctx.addEllipse(in: CGRect(x: x - 54, y: y - 54, width: 108, height: 108))
    ctx.fillPath()
}
ctx.restoreGState()

// Write PNG.
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
          outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("could not create PNG destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fail("could not write PNG") }
APPICON_SWIFT_EOF

  if [[ -f "$RENDER_SRC" ]] && cmp -s "$tmp" "$RENDER_SRC"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$RENDER_SRC"
  fi
}

try_swift() {
  write_swift_source || return 1
  if [[ ! -x "$RENDER_BIN" ]] || [[ "$RENDER_SRC" -nt "$RENDER_BIN" ]]; then
    info "compiling bundled Swift/CoreGraphics icon renderer"
    swiftc -O "$RENDER_SRC" -o "$RENDER_BIN" >/dev/null 2>&1 || {
      echo "error: swiftc failed to compile the icon renderer ($RENDER_SRC)" >&2
      return 1
    }
  fi
  "$RENDER_BIN" "$PNG" || return 1
  valid_png "$PNG"
}

# ---------------------------------------------------------------------------
# Step 1: rasterise the SVG to a 1024x1024 PNG.
# ---------------------------------------------------------------------------
RENDERER=""
if try_rsvg; then
  RENDERER="rsvg-convert"
elif try_inkscape; then
  RENDERER="inkscape"
elif try_cairosvg; then
  RENDERER="cairosvg"
elif try_qlmanage; then
  RENDERER="qlmanage (macOS Quick Look)"
elif try_swift; then
  RENDERER="bundled Swift/CoreGraphics"
else
  die "no renderer produced a valid 1024x1024 PNG (tried rsvg-convert, inkscape, cairosvg, qlmanage, bundled swiftc)"
fi
info "rasterised AppIcon.svg with $RENDERER"

# ---------------------------------------------------------------------------
# Step 2: build the .iconset (16/32/128/256/512, each 1x and 2x).
# ---------------------------------------------------------------------------
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

gen_size() {
  local px="$1" name="$2"
  sips -z "$px" "$px" "$PNG" --out "$ICONSET/$name" >/dev/null 2>&1 \
    || die "sips failed to render $name (${px}x${px})"
}

gen_size 16   "icon_16x16.png"
gen_size 32   "icon_16x16@2x.png"
gen_size 32   "icon_32x32.png"
gen_size 64   "icon_32x32@2x.png"
gen_size 128  "icon_128x128.png"
gen_size 256  "icon_128x128@2x.png"
gen_size 256  "icon_256x256.png"
gen_size 512  "icon_256x256@2x.png"
gen_size 512  "icon_512x512.png"
gen_size 1024 "icon_512x512@2x.png"

# ---------------------------------------------------------------------------
# Step 3: pack the iconset into the .icns.
# ---------------------------------------------------------------------------
rm -f "$ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS" >/dev/null 2>&1 \
  || die "iconutil failed to convert $ICONSET to .icns"
[[ -s "$ICNS" ]] || die "iconutil produced an empty .icns"

# ---------------------------------------------------------------------------
# Step 4: validate. An icns -> iconset round trip proves the bundle is a real,
# parseable macOS icon; sips confirms the largest representation is 1024px.
# ---------------------------------------------------------------------------
VERIFY="$BUILD/.AppIcon.verify.iconset"
rm -rf "$VERIFY"
iconutil -c iconset "$ICNS" -o "$VERIFY" >/dev/null 2>&1 \
  || die "generated .icns failed an iconutil round-trip (invalid icon bundle)"
biggest="$(find "$VERIFY" -name '*.png' -exec sips -g pixelWidth {} \; 2>/dev/null \
  | awk '/pixelWidth/{print $2}' | sort -n | tail -1)"
[[ "$biggest" == "1024" ]] \
  || die "largest icon representation is ${biggest:-none}px, expected 1024"
count="$(find "$VERIFY" -name '*.png' | wc -l | tr -d ' ')"
rm -rf "$VERIFY"

info "validated $ICNS ($(stat -f%z "$ICNS") bytes, $count representations, largest 1024px)"
echo "== generated $ICNS"
