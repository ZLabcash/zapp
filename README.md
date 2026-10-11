# ZApp

> [!WARNING]
> **Experimental software. Not audited.** ZApp and the ZFlip Flipper app are research
> prototypes. Use them only with small amounts you can afford to lose and keep your 24 words on
> paper. No warranty of any kind (see the licenses).

The iPhone app for hardware Zcash signers: a [ZFlip](https://github.com/ZLabcash/zflip)
Flipper Zero over Bluetooth today, a Kindle soon. Watch-only: it holds the viewing key, syncs,
builds and proves transactions, and broadcasts them. The device shows each payment and signs.

SwiftUI and ZcashLightClientKit. Build the Rust bridge first, with the zflip repo checked out
next to this one as `flipper-zero/`:

    ./scripts/build-bridge.sh
    xcodegen && open ZFlip.xcodeproj

Set your own team in `project.yml` (`DEVELOPMENT_TEAM`) to run it on a device.

## License

MIT or Apache-2.0, at your option.

Flag images in `ZFlip/Assets.xcassets/Flags` come from [flag-icons](https://github.com/lipis/flag-icons) (MIT, © Panayiotis Lipiridis).
