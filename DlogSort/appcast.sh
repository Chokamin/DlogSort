#!/bin/zsh
# 给 Sparkle 更新源 docs/appcast.xml 加上本次版本：先运行 build.sh、notarize.sh，再运行本脚本
# 用法: ./DlogSort/appcast.sh 发布说明.html
# 发布说明是一段 HTML（如 <ul><li>…</li></ul>），会显示在 Sparkle 的更新窗口里
# 签名用钥匙串里账户名为 DlogSort 的 EdDSA 私钥（generate_keys --account DlogSort 生成）
set -e
cd "$(dirname "$0")/.."
NOTES="$1"
[ -f "$NOTES" ] || { echo "用法: $0 发布说明.html"; exit 1; }
APPCAST="${APPCAST:-docs/appcast.xml}"
INFO="$PWD/DlogSort.app/Contents/Info"
VERSION=$(defaults read "$INFO" CFBundleShortVersionString)
BUILD=$(defaults read "$INFO" CFBundleVersion)
URL="${DOWNLOAD_URL:-https://github.com/Chokamin/DlogSort/releases/download/v$VERSION/DlogSort.zip}"
# 输出形如 sparkle:edSignature="..." length="..."
SIG=$(Vendor/Sparkle-2.10.0/bin/sign_update --account DlogSort DlogSort.zip)

python3 -I - "$APPCAST" "$VERSION" "$BUILD" "$URL" "$SIG" "$NOTES" <<'PY'
import sys, os, email.utils
# Sparkle 用网页视图显示说明，没有样式时列表会缩进 40px、字号偏大，这里统一成系统字体和较小的缩进
STYLE = ("<style>:root{color-scheme:light dark}"
         "body{margin:10px 14px;font:13px/1.55 -apple-system,'PingFang SC',sans-serif}"
         "ul{margin:0;padding-left:1.1em}li{margin:0 0 6px}p{margin:0 0 8px}</style>")
path, version, build, url, sig, notes = sys.argv[1:]
if not os.path.exists(path):
    open(path, "w").write('''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DlogSort</title>
    <link>https://chokamin.github.io/DlogSort/appcast.xml</link>
  </channel>
</rss>
''')
feed = open(path).read()
if f"<sparkle:version>{build}</sparkle:version>" in feed:
    sys.exit(f"appcast 里已经有 build {build}，请先在 build.sh 里递增 BUILD")
item = f'''    <item>
      <title>DlogSort {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{STYLE}{open(notes).read().strip()}]]></description>
      <enclosure url="{url}" {sig} type="application/octet-stream"/>
    </item>
'''
# 新版本放在最前面
anchor = "  </channel>" if "<item>" not in feed else "    <item>"
i = feed.index(anchor)
open(path, "w").write(feed[:i] + item + feed[i:])
print(f"已写入 {path}: {version} (build {build})")
PY
