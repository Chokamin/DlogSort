#!/bin/zsh
# 公证并生成发布用的 zip：先运行 build.sh，再运行本脚本
# 需要事先保存公证凭据（只需一次）：
#   xcrun notarytool store-credentials DlogSort-notary --apple-id 你的AppleID --team-id 你的TeamID
set -e
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-DlogSort-notary}"
ZIP="DlogSort.zip"
rm -f "$ZIP"
ditto -c -k --keepParent DlogSort.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
# 把公证票据钉进 app，离线也能通过 Gatekeeper 检查，然后重新打包
xcrun stapler staple DlogSort.app
rm -f "$ZIP"
ditto -c -k --keepParent DlogSort.app "$ZIP"
spctl -a -vv -t exec DlogSort.app
echo "已生成: $(pwd)/$ZIP"
