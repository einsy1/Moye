#!/bin/zsh
set -eu
cd "${0:A:h}"
npm run build
swift Sources/icon.swift dist/Moye.iconset
iconutil -c icns dist/Moye.iconset -o dist/Moye.icns
APP="$PWD/dist/墨页 2.0.1.app"
if pgrep -f "^${APP}/Contents/MacOS/Moye$" >/dev/null; then
  echo "请先退出正在运行的 2.0.1，再重新构建。" >&2
  exit 1
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
printf 'CFBundleDisplayName = "墨页";\n' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
cp -X dist/Moye.icns "$APP/Contents/Resources/Moye.icns"
cp -X web/index.html web/style.css dist/editor.js web/assistant.html web/assistant.js web/assistant.css "$APP/Contents/Resources/web/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIconFile</key><string>Moye.icns</string><key>CFBundleDevelopmentRegion</key><string>zh_CN</string><key>CFBundleLocalizations</key><array><string>zh-Hans</string></array><key>CFBundleName</key><string>墨页</string><key>CFBundleDisplayName</key><string>墨页</string><key>CFBundleExecutable</key><string>Moye</string><key>CFBundleIdentifier</key><string>com.neil.moye</string><key>CFBundleVersion</key><string>10</string><key>CFBundleShortVersionString</key><string>2.0.1</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/><key>NSPrincipalClass</key><string>NSApplication</string><key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Markdown 文稿</string><key>CFBundleTypeRole</key><string>Editor</string><key>LSHandlerRank</key><string>Default</string><key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string><string>app.markedit.md</string><string>app.markedit.markdown</string><string>public.plain-text</string></array><key>CFBundleTypeExtensions</key><array><string>md</string><string>markdown</string><string>mdown</string><string>txt</string></array></dict></array></dict></plist>
PLIST
swiftc Sources/CodexAssistant.swift Sources/main.swift Sources/TitlebarDragView.swift Sources/Storage.swift Sources/WebDAV.swift -target arm64-apple-macos13.0 -O -o "$APP/Contents/MacOS/Moye" -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers -framework Security -framework PDFKit
node scripts/licenses.mjs "$APP/Contents/Resources/Licenses"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
