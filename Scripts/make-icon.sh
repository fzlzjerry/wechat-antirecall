#!/bin/bash
# Generates Resources/AppIcon.icns from a rendered 1024px PNG using only system tools
# (swift + sips + iconutil). Run once; the .icns is checked into the repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SWIFT_SRC="$WORK/render.swift"
cat > "$SWIFT_SRC" <<'SWIFT'
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Rounded-rect background with a calm green gradient.
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let corner = size * 0.2237   // macOS icon superellipse-ish radius
let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
path.addClip()
let top = NSColor(calibratedRed: 0.16, green: 0.72, blue: 0.47, alpha: 1)
let bottom = NSColor(calibratedRed: 0.07, green: 0.52, blue: 0.33, alpha: 1)
NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)

// White shield glyph centered.
let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: symbol.size)
    symbol.draw(in: r)
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()
    let w = symbol.size.width, h = symbol.size.height
    let drawRect = NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h)
    tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 0.95)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render icon\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

PNG="$WORK/icon_1024.png"
swift "$SWIFT_SRC" "$PNG"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  px="${spec%% *}"; name="${spec##* }"
  sips -z "$px" "$px" "$PNG" --out "$ICONSET/icon_$name.png" >/dev/null
done

mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo ">> Wrote $ROOT/Resources/AppIcon.icns"
