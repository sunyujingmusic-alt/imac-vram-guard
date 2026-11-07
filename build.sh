#!/bin/bash
# 构建 "iMac 显存管家" macOS APP
# 目标：iMac19,1 (Intel x86_64) / macOS 13.7+ — 不使用 App Sandbox（需调用 pmset / displayplacer）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="iMac 显存管家"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
CONTENTS="$APP/Contents"
TARGET="x86_64-apple-macosx13.0"

echo "==> 清理旧的构建产物"
rm -rf "$BUILD"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "==> 生成应用图标"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
if /usr/bin/swiftc -O -target "$TARGET" -o "$BUILD/makeicon" "$ROOT/src/makeicon.swift" 2>/dev/null; then
    "$BUILD/makeicon" "$ICONSET" >/dev/null 2>&1 || true
    /usr/bin/iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns" 2>/dev/null || true
fi

echo "==> 编译 Swift 源码（$(ls "$ROOT"/src/*.swift | grep -v makeicon | wc -l | tr -d ' ') 个文件）"
SOURCES=()
for f in "$ROOT"/src/*.swift; do
    [[ "$(basename "$f")" == "makeicon.swift" ]] && continue
    SOURCES+=("$f")
done
/usr/bin/swiftc -O -target "$TARGET" -o "$CONTENTS/MacOS/VRamGuard" "${SOURCES[@]}"

echo "==> 写入 Info.plist"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>iMac 显存管家</string>
  <key>CFBundleDisplayName</key>       <string>iMac 显存管家</string>
  <key>CFBundleIdentifier</key>        <string>com.sunyujing.vramguard</string>
  <key>CFBundleExecutable</key>        <string>VRamGuard</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key>           <string>2</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key> <string>zh_CN</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>  <string>iMac 5K 三屏显存管家</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc 签名（无沙箱，允许调用 pmset / displayplacer）"
/usr/bin/codesign --force --deep --sign - "$APP"

echo "==> 完成：$APP"
/usr/bin/codesign -dv "$APP" 2>&1 | head -3 || true
