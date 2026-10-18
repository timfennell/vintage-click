#!/bin/zsh
# Builds Crank & Click.app with swiftc (no Xcode needed: Command Line Tools only).
# SPIRULA_BUILD points at a spirula-studio build containing libspirula_render.dylib.
set -e
cd "$(dirname "$0")"
SPIRULA_BUILD=${SPIRULA_BUILD:-$HOME/Documents/spirula-studio-capture/build}
APP="build/Crank & Click.app"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
# The Command Line Tools ship SwiftBridging twice (module.modulemap and
# bridging.modulemap), which breaks any C module import; hide one copy.
TOOLS_SWIFT_INC=/Library/Developer/CommandLineTools/usr/include/swift
VFS=()
if [[ -f $TOOLS_SWIFT_INC/module.modulemap && -f $TOOLS_SWIFT_INC/bridging.modulemap ]]; then
    : > build/empty.modulemap
    cat > build/vfs.yaml <<VFSEOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "name": "$TOOLS_SWIFT_INC", "type": "directory",
  "contents": [ { "name": "module.modulemap", "type": "file", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
VFSEOF
    VFS=(-vfsoverlay build/vfs.yaml -Xcc -ivfsoverlay -Xcc build/vfs.yaml)
fi
swiftc "${VFS[@]}" -O -wmo -target arm64-apple-macos14.0 \
    -I Sources/CSpirula -L "$SPIRULA_BUILD" -lspirula_render \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/SplatCamera/*.swift -o "$APP/Contents/MacOS/CrankAndClick"
cp "$SPIRULA_BUILD/libspirula_render.dylib" "$APP/Contents/Frameworks/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The camera's own sounds (recorded from a Nikon for the game).
rm -rf "$APP/Contents/Resources/Sounds"
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
codesign --force --sign - "$APP/Contents/Frameworks/libspirula_render.dylib" "$APP" >/dev/null 2>&1
echo "Built $APP"
