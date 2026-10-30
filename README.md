# Opal Studio

A native macOS camera application for the Opal C1, built in this folder after inspecting the installed Opal Composer 2.0 (build 24). The requested Reverse Engineer Anything skill and CLI were used; evidence is indexed in [research/REVERSE_ENGINEERING.md](research/REVERSE_ENGINEERING.md).

## Current status

The project builds a signed macOS app and a CoreMediaIO camera extension. It implements adjustable person-aware background blur, lighting adjustments, eight selective color bands, face tracking, zoom, physical stock-C1 focus, eight Core Image photo filters and five reconstructed custom looks, touch-up, pixelation, presets, short video loops, local H.264/AAC recording, histogram and zebra preview aids, and 360p/720p/1080p/1440p/4K output. Background replacement and decorations are deliberately excluded from the interface at the user's request.

**This is not yet a verified exact clone or a proven zero-flicker replacement.** The current pipeline executes Composer's shipped GPU shaders or embedded Metal source for camera decoding, bokeh, Touch Up, custom looks, HSV, lighting and mask blending. Segmentation and face tracking follow the recovered model selection and parameters. Independent native-shader comparisons cover full-frame and cropped output; these do not establish whole-camera equality. Original `.opalPreset` imports preserve recovered controls and unknown fields. See the [current parity audit](research/BUILD17_PARITY_AUDIT.md) for evidence and remaining gaps. Stock C1 optical focus uses the recovered USB control sequence and calibrated distance mapping. The optional firmware-loading backend remains experimental and is omitted from distribution builds.

## Run

Open `/Applications/Opal Studio.app`; the camera starts automatically. If Composer is holding the C1, turn its camera off and quit it. Studio retries every two seconds and starts once the device is released. Turning Studio’s camera off explicitly cancels automatic retries until you turn it on again or relaunch the app.

For meeting output, open Settings (Command-comma) → Video → Advanced, install the camera extension, and approve **Opal Studio Camera** in System Settings → General → Login Items & Extensions → By Category → Camera Extensions. Connect the virtual camera and select **Opal Studio Camera** in the meeting application.

The default input uses the camera's stock UVC mode. **C1 sensor controls is experimental and currently fails to start on this C1.** Its intended controls are physical focus, exposure/shutter/ISO, white balance, and antibanding; use stock capture for reliable video until this path is resolved. This direct mode temporarily boots a DepthAI runtime into camera RAM; it does not request a flash write. The C1's stock camera and microphone disconnect during direct mode. Use another microphone for meetings. Stop or quit cleanly to restore stock operation; a USB reconnect may be necessary after an abnormal exit. The latest failed RAM handoff returned to stock mode automatically. It did not validate physical controls.

## Install on another Mac

Download the universal DMG from the private [GitHub releases](https://github.com/flowtricks/opal-app/releases), open it, drag Opal Studio to Applications, and eject the disk image before launching the app. A ZIP is also available. The app requires macOS 14 or later. Developer ID distribution does not require registering each laptop with Apple.

The accepted, notarized build is [0.1.0 (19)](https://github.com/flowtricks/opal-app/releases/tag/v0.1.0-build19). Private auto-updates start with build 18.

Each Mac must grant camera/microphone access as needed and approve **Opal Studio Camera** in System Settings → General → Login Items & Extensions → Camera Extensions. Set login and camera-plug-in launch preferences in Settings → General. Avoid leaving Composer's own camera connection active at the same time.

## Private updates

Build 18 and later update themselves with Sparkle. On each Mac, open Settings → Updates, create a fine-grained GitHub token limited to `flowtricks/opal-app` with Contents: Read-only, and connect. The token stays in that Mac's Keychain and is sent only to this repository's GitHub API endpoints. Updates download automatically and install once the camera, recordings, loops and tests are idle, or on quit. **Check for Updates** is in Settings → Updates and the app menu.

To publish an update, package the notarized DMG, then run `scripts/publish-update.sh`. It signs the DMG with the Sparkle EdDSA key in the login Keychain (account `flowtricks-opal-studio`), uploads it to the build's GitHub release, and rewrites `updates/appcast.xml`. Commit and push that appcast to `main` to make the update live. Sparkle 2.10.0's command-line tools are expected in `build/sparkle-tools`.

## Build and release

Requires macOS 14 or later and Xcode. The universal distribution includes stock UVC capture/control and excludes the experimental ARM-only DepthAI runtime. This keeps ordinary installation independent of firmware loading and third-party SDK binaries.

```sh
swift test
scripts/archive-release.sh
scripts/notarize-release.sh
# After Apple finishes processing:
scripts/package-release.sh
scripts/package-dmg.sh
```

Sign in to Xcode with the development team's account first. The scripts use Developer ID Application signing, hardened runtime, automatic distribution provisioning, and Xcode's notarization service. No passwords, private keys, signing profiles, camera recordings, or local reverse-engineering databases are committed. Packaging requires successful signature verification, an Apple notarization ticket, Gatekeeper acceptance, and both CPU architectures in all three executables.

If command-line upload reports “No Accounts” despite a valid Xcode account, use Organizer → Distribute App → Direct Distribution on the archive. After notarization succeeds, `scripts/package-release.sh /absolute/path/to/accepted.xcarchive` exports and verifies that archive; then run `scripts/package-dmg.sh`.

The team is `G766RX9X84`. App groups and the camera extension's Mach service prefix must match. `build/notarized-app-path.txt` records the verified notarized export location; the portable ZIP, signed DMG containing the notarized app, and SHA-256 checksums are written to `dist/`. Raw local research evidence referenced by the written audits is intentionally not included in Git.

For development with the experimental DepthAI backend only, run `scripts/build-c1-backend.sh`, then `python3 scripts/generate-xcode-project.py` without the distribution flag and build ARM64. This backend is not needed for stock-C1 optical focus. For a preview-only build, `scripts/build-preview.sh` omits the restricted extension-install entitlement and cannot install a virtual camera.

## Reliability design

- Processed frames are fully rendered into separate IOSurface-backed buffers before publication.
- The transport makes immutable opaque copies with stride validation and bounded buffer pools.
- Capture, effects, output pacing, recording and virtual-camera consumption use bounded handoffs.
- The live preview renders pixel buffers directly through Metal. Slow CG thumbnails are computed separately and never block processing.
- Completed live frames are delivered immediately with host-clock timestamps and bounded pacing; a watchdog repeats the last complete frame only after a 45 ms gap.
- Stale camera images expire to an opaque interruption screen. UVC recovery uses at most three attempts with backoff; it does not silently change to a different physical camera.
- Recording and loop encoding cannot accumulate an unbounded queue of full-resolution frames.
- USB discovery reads cached IORegistry data; it does not open/seize the camera.

These measures address plausible corruption and pacing failure modes. They cannot promise that a camera, USB connection, OS driver or conferencing service will never fail. Full client validation remains necessary.

## Source map

- `Sources/OpalApp`: native interface, persistence, local recording, C1 runtime loader.
- `Sources/OpalCore`: capture/effects, loops, recovery, preview analysis.
- `Sources/CameraBridge`: app-to-extension sink transport.
- `Sources/CameraExtension`: virtual camera and consumer format conversion.
- `Sources/C1Bridge`: independently written C ABI over the pinned public DepthAI SDK.
- `Tests`: deterministic timing, frame ownership, opacity, effects, loop and recovery tests.
- `research`: REA evidence, installed-app observations, uncertainties, and hardware audit.

The requested Composer app icon, logo, settings icons, loading animation, compiled GPU shaders, embedded Metal source, and segmentation/face models are retained for this private personal build. No Opal firmware or fonts are copied into the distribution. Third-party SDK/runtime dependencies and notices are documented in `Sources/C1Bridge/README.md` and packaged in the app's C1Licenses resources.
