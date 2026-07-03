#!/bin/zsh
set -e

APP_NAME="CleanMyMacBook"
SCHEME="CleanMyMacBook"
BUILD_DIR="$(pwd)/.build"
DMG_STAGING="$BUILD_DIR/dmg_staging"
DMG_OUT="$(pwd)/$APP_NAME.dmg"

echo "▶ 清理旧产物..."
rm -rf "$BUILD_DIR"
mkdir -p "$DMG_STAGING"

echo "▶ 编译 Release..."
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="-" \
  build

APP_SRC="$BUILD_DIR/derived/Build/Products/Release/$APP_NAME.app"

echo "▶ 复制 .app 到暂存目录..."
cp -r "$APP_SRC" "$DMG_STAGING/$APP_NAME.app"

# 添加 Applications 快捷方式，方便拖拽安装
ln -sf /Applications "$DMG_STAGING/Applications"

echo "▶ 生成 DMG..."
rm -f "$DMG_OUT"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG_OUT"

rm -rf "$BUILD_DIR"

echo "✅ 完成：$DMG_OUT"
open -R "$DMG_OUT"
