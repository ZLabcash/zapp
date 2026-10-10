#!/bin/sh
# Builds ZFlipBridge.xcframework (the Rust PCZT <-> Flipper glue) for iPhone and the
# simulator. A dynamic framework, so its Rust runtime cannot clash with the one
# inside the Zcash SDK's libzcashlc.
set -e
# The bridge crate lives in the zflip repo, checked out next to this one.
cd "$(dirname "$0")/.."
OUT=$PWD/Frameworks
ZFLIP=${ZFLIP:-$PWD/../flipper-zero}
cd "$ZFLIP"
NAME=ZFlipBridge
rm -rf "$OUT/$NAME.xcframework" target/ios-frameworks
for TARGET in aarch64-apple-ios aarch64-apple-ios-sim; do
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  RUSTFLAGS="-C link-arg=-Wl,-install_name,@rpath/$NAME.framework/$NAME" \
    cargo build -p zflip-bridge --release --target "$TARGET"
  FW=target/ios-frameworks/$TARGET/$NAME.framework
  mkdir -p "$FW/Headers" "$FW/Modules"
  cp "target/$TARGET/release/libzflip_bridge.dylib" "$FW/$NAME"
  cp bridge/include/zflip_bridge.h "$FW/Headers/"
  printf 'framework module %s {\n  header "zflip_bridge.h"\n  export *\n}\n' "$NAME" > "$FW/Modules/module.modulemap"
  cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>cash.zscan.zflip.bridge</string>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.0</string>
</dict></plist>
PLIST
done
xcodebuild -create-xcframework \
  -framework target/ios-frameworks/aarch64-apple-ios/$NAME.framework \
  -framework target/ios-frameworks/aarch64-apple-ios-sim/$NAME.framework \
  -output "$OUT/$NAME.xcframework"
