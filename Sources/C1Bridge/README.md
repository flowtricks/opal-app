# Independent C1 sensor backend

This bridge is newly written against the public Luxonis DepthAI SDK. It is not extracted Composer code. `scripts/build-c1-backend.sh` builds the pinned v2.30.0 commit `e0f6b52d048ef7ceac2ecd44deb2e161dbb97699`, local dependencies, the bridge, and camera-free control regressions. It never opens a camera. CMake/Ninja and Hunter's cache stay within this project.

The three output libraries in `build/c1/` belong together under the app's `Contents/Frameworks/C1Bridge/`, signed with the same identity as the host. Include `build/c1/licenses/` in the app's resources. The Swift `C1API` target contains only the C declarations; the app loads the runtime dynamically, so it can still run UVC capture when the optional backend is not packaged.

`C1Controller` loads the library at initialization but does not enumerate or open a camera automatically. `refreshDevices()` reads cached IORegistry properties without opening USB handles. `start(camera:)` requires the explicitly selected device. Opening the device temporarily loads a public DepthAI runtime into RAM and replaces stock UVC capture; the stock C1 microphone can disappear too. Stopping closes the SDK session and requests the return to stock firmware. The camera may need several seconds to re-enumerate. No bridge path calls a flash-writing API. Recovery from every physical disconnect or SDK hang is not guaranteed by source inspection.

Use `C1Controller.shutdown(completion:)` from an asynchronous AppKit termination flow so close finishes before process exit. Do not close from the frame/status callback. SDK close may block on hardware, so it runs on the controller's serial lifecycle worker. The app should keep a clear closing state while waiting; an unplugged device can require reconnecting.

The frame callback provides temporary NV12 pointers. The Swift receiver copies valid planes row-by-row into an owned IOSurface-backed buffer, then submits it to the existing bounded effects pipeline. A pool threshold limits allocations. The C callback's host timestamp is arrival time based on `mach_absolute_time`, not the sensor's exposure timestamp; it must not be represented as measured glass-to-glass latency.

Hardware controls include optical lens position (0–255, not meters), exposure time/ISO, auto-exposure lock/compensation, white balance/lock, antibanding, sharpness and denoise. Digital image controls remain in the effects pipeline. Only changed sensor commands are sent, so a color/exposure edit does not restart autofocus.

Validation completed during implementation:

- SDK and C bridge compile successfully on local Xcode 27, arm64, macOS deployment target 14.
- Seven real SDK control-message assertions pass without opening USB: no-op suppression, exposure delta, autofocus isolation, manual focus payload, return to autofocus, white-balance isolation, and bounds/default command coverage.
- Dynamic library load and enumeration found one identifiable Opal C1 in stock mode (`03e7:f63d`). An initial libusb descriptor enumeration was replaced with passive IORegistry reads after auditing Darwin libusb behavior; see `research/C1_ENUMERATION_AUDIT.md`.
- The full Swift app release build passes with the dynamic wrapper.

Direct-mode live attempts have failed during handoff; one required USB reconnection. The bridge now delegates version-aware RAM boot to the pinned SDK and drops only stale USB-path constraints while preserving exact hardware identity. See `research/C1_ENUMERATION_AUDIT.md`. Successful takeover, manual-control response, reconnect/shutdown recovery, microphone behavior, and sustained Meet/Zoom validation remain required. Camera-free builds/tests do not establish hardware success.

## Source and dependency provenance

The bridge and Swift wrapper are original project source. Public [`alii/open-opal`](https://github.com/alii/open-opal) at `1f12785973d73982cacbeccd7b8924cf4e3de40a` informed the hardware feasibility review; no implementation or vendor assets were copied. Its README declares MIT, but that checkout has no LICENSE file, so it is kept only as a research reference.

The SDK source is [`luxonis/depthai-core`](https://github.com/luxonis/depthai-core/tree/e0f6b52d048ef7ceac2ecd44deb2e161dbb97699), MIT. `prepare-c1-sdk.py` records our small changes: USB-only XLink discovery, a narrowly limited version-zero bootloader message gate, and zlib compatibility with the installed macOS SDK. The bridge's use of bootloader methods does not call flash programming APIs. The downloaded device runtime is a prebuilt SDK resource, not source-reconstructed camera firmware: SDK device commit `a62b2ccb0bc493c2fb41694cb81c08887be24c52`, bootloader resource version `0.0.28`.

`build/c1/licenses/` retains the SDK/dependency notices including libusb's LGPL 2.1 text, XLink, spdlog/fmt, JSON, archive/compression, and utility libraries. libusb remains a separate dynamic library. The device/bootloader resource archives contain no separate license notice; this documentation does not assert that the source SDK's MIT notice alone establishes every binary resource's redistribution terms. Preserve resource provenance and check those terms before separately distributing a release. The current local build's source, patches, and dependency cache remain available in this project.

Enumeration is passive IORegistry inspection. Explicit Start is the boundary that begins device communication and RAM runtime replacement. `isClosing` stays true until SDK close returns; UVC restart must wait for `stop(completion:)` and for the stock camera to reappear. Sensor/control behavior and audio availability must still be validated on the physical camera.
