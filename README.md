# ZApp

The phone app for hardware signers: a [ZFlip](https://github.com/Zfactorycash/zflip)
Flipper Zero over Bluetooth, and soon a [ZKindle](https://github.com/Zfactorycash/zkindle)
over local Wi-Fi. Watch-only: it syncs, prepares and proves; the device signs.

iOS (SwiftUI, ZcashLightClientKit). Build the bridge first, with the zflip repo
checked out next to this one as `flipper-zero/`:

    ./scripts/build-bridge.sh
    xcodegen && open ZFlip.xcodeproj
