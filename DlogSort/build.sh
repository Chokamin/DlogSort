#!/bin/zsh
# 编译并打包成 "DlogSort.app"，输出到本脚本的上一级目录
set -e
cd "$(dirname "$0")"
# 版本号：每次发布都要递增 BUILD，Sparkle 靠它判断新旧
VERSION="${VERSION:-1.4}"
BUILD="${BUILD:-6}"
APP="${APP:-$(cd .. && pwd)/DlogSort.app}"
# 测试更新流程时可以换成别的标识和本地更新源
BUNDLE_ID="${BUNDLE_ID:-io.github.chokamin.dlogsort}"
FEED_URL="${FEED_URL:-https://chokamin.github.io/DlogSort/appcast.xml}"
# Sparkle 更新框架：缺少时自动下载固定版本并校验
SPARKLE_VER=2.10.0
SPARKLE_SHA=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE="$(cd .. && pwd)/Vendor/Sparkle-$SPARKLE_VER"
if [ ! -d "$SPARKLE/Sparkle.framework" ]; then
  mkdir -p "$SPARKLE"
  curl -sSL -o "$SPARKLE.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VER/Sparkle-$SPARKLE_VER.tar.xz"
  echo "$SPARKLE_SHA  $SPARKLE.tar.xz" | shasum -a 256 -c -
  tar -xJf "$SPARKLE.tar.xz" -C "$SPARKLE"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# 生成图标
TMP=$(mktemp -d)
if xcrun --find actool >/dev/null 2>&1; then
  # 有 Xcode：编译成 macOS 26+ 的系统图标格式（由系统套圆角，不会被放进灰色框），同时生成兼容旧系统的 icns
  mkdir -p "$TMP/AppIcon.icon/Assets"
  swift make_icon.swift "$TMP/AppIcon.icon/Assets/art.png" --full-bleed
  cat > "$TMP/AppIcon.icon/icon.json" <<'JSON'
{
  "groups" : [
    {
      "layers" : [ { "image-name" : "art.png", "name" : "art", "glass" : false } ],
      "shadow" : { "kind" : "none", "opacity" : 0 },
      "translucency" : { "enabled" : false, "value" : 0 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
JSON
  xcrun actool "$TMP/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$TMP/partial.plist" >/dev/null
else
  # 没有 Xcode：自己画好圆角底板，打包成 icns
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift make_icon.swift "$ICONSET/icon_512x512@2x.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
# 编译 Apple 芯片和 Intel 两种架构，合并成通用二进制，最低支持 macOS 14
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos14.0 -o "$TMP/DlogSort-$arch" main.swift \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
done
lipo -create "$TMP/DlogSort-arm64" "$TMP/DlogSort-x86_64" -output "$APP/Contents/MacOS/DlogSort"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# 应用没有开沙盒，用不到 Sparkle 的 XPC 服务
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DlogSort</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>DlogSort</string>
  <key>CFBundleDisplayName</key><string>DlogSort</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>94dmfAZqqUP/jYghX8xWTCwdIn6FtVVpdSe43KwgfNI=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF
# 有 Developer ID 证书就正式签名（开启 hardened runtime，公证必需），否则用临时签名
SIGN_ID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
# Sparkle 里的辅助程序要先单独签名，再签框架，最后签整个应用
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -n "$SIGN_ID" ]; then
  sign() { codesign --force --options runtime --timestamp -s "$SIGN_ID" "$@"; }
  echo "已签名: $SIGN_ID"
else
  sign() { codesign --force -s - "$@"; }
fi
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP"
echo "已生成: $APP"
