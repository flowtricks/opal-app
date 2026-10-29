# C1 hardware control options

Read-only source review, October 29, 2026. No camera command, USB reset, firmware upload, or third-party app launch was performed. The source reference is checked out at `research/vendor/open-opal`, commit `1f12785973d73982cacbeccd7b8924cf4e3de40a`, from [alii/open-opal](https://github.com/alii/open-opal/tree/1f12785973d73982cacbeccd7b8924cf4e3de40a).

## Recommendation

Keep UVC capture as the simple stock-firmware backend. To add independent C1 sensor focus, exposure and white balance, implement a separate **DepthAI capture backend** using the public C bridge in Open Opal. It must own capture and controls together. It cannot be bolted onto a concurrently running UVC session as a control-only slider.

The [public bridge source](https://github.com/alii/open-opal/blob/1f12785973d73982cacbeccd7b8924cf4e3de40a/Sources/OpalBridge/OpalBridge.cpp) uses Luxonis CameraControl commands for manual focus, exposure, white balance and antibanding. Its opener configures an on-camera pipeline, owns USB/XLink capture, and its closer releases the device. The source exposes a C ABI with callbacks, making reuse in the Swift app feasible. The important integration contract is that callback NV12 pointers expire when the callback returns: copy the pixels before queuing them for processing. Inspect the preserved source for exact structures and signatures.

## Hardware behavior and boundaries

Open Opal's [technical notes](https://github.com/alii/open-opal/blob/1f12785973d73982cacbeccd7b8924cf4e3de40a/TECHNICAL.md) describe a temporary runtime takeover: reset the VPU, upload DepthAI firmware to RAM, install the capture/control pipeline, then return to stock firmware on quit. This interrupts the stock UVC device. Early IMX378 units require a separate bootloader handoff; source matching requires the selected device's MxID across reconnection. There is no observed flash-writing call in the reviewed bridge, but this review is not a hardware safety proof or a complete dependency audit. Do not repeat upstream's absolute claim that bricking is impossible.

Microphone availability during the custom runtime must be checked. The independent [decomposer hardware notes](https://github.com/fidecastro/decomposer/blob/main/docs/camera-notes.md) report that stock C1 UVC autofocus/white-balance auto switches were read-only on the tested firmware, preventing manual focus via standard UVC. They also report that their DepthAI runtime lacks the stock UAC2 microphone. Those are observations on another machine/firmware, not this user's device.

The generic [libuvc API](https://github.com/libuvc/libuvc/blob/master/include/libuvc/libuvc.h) exposes focus-auto and focus-absolute requests, but existence of an API or descriptor does not prove that the C1 accepts its writes. The official [Luxonis CameraControl API](https://docs.luxonis.com/software-v3/depthai/depthai-components/messages/camera_control) documents manual lens position 0–255 and exposure in microseconds plus ISO. No documented, verified control-only protocol for Composer's running stock firmware was established by this review.

## Build and licensing review

| Item | Finding |
| --- | --- |
| Compiler | Local Xcode 27.0 (`27A266a`) meets upstream's stated Xcode 27 requirement. |
| Build utilities | `cmake`, `ninja`, `xcodegen` were absent from PATH at inspection. |
| Capture dependency | `scripts/bootstrap.sh` fetches DepthAI v2.30.0 recursively, builds with Hunter dependencies, applies a narrowly scoped early-camera bootloader patch and a USB-only discovery patch. It stages `libdepthai-core` and `libusb` locally. No bootstrap was run. Pin the resolved SDK commit and dependency artifacts before adoption. |
| Optional model | Depth Anything model fetch uses a moving Hugging Face `main` URL. It is not required for Vision-only blur; omit it or pin/checksum it separately. |
| License | README declares MIT. No standalone LICENSE file or complete MIT copyright notice exists in this checkout. Keep source provenance and README; verify/retain license texts for SDK and transitive dependencies before redistribution. No third-party implementation has been incorporated into production source in this research step. |
| Signing | Upstream project embeds another developer's IDs. Its signing script/profiles are not portable as-is. Use the user's app IDs/team/groups and valid host + extension profiles. |
| Camera-free tests | `scripts/tests/test_boot_safety.py`, `control_delta_test.cpp`, and USB-only discovery tests exist. Hardware probes are separate. None were run during source review. |
| Stability | Upstream is a young project with useful regressions; its existence is not evidence of zero flicker in the user's Meet/Zoom environment. |

## Minimal integration sequence

1. Build the pinned public bridge and SDK without running hardware probes. Preserve upstream attribution and dependency license information.
2. Add a distinct C1/DepthAI backend choice, keeping the default UVC path available. Explain the temporary device/microphone interruption before its first use.
3. Stop UVC capture before opening DepthAI. Bind to the selected C1 identity, never the first arbitrary USB device. Keep connection/close work off the main thread; prevent overlapping opens and closes.
4. Copy each NV12 callback to an owned pixel buffer and feed the existing segmentation/color/output pipeline. Keep output format fixed and opaque.
5. Add sensor controls only once connected. Distinguish optical lens position from digital blur and digital exposure. Send changed controls so exposure edits do not restart autofocus.
6. Verify shutdown returns stock UVC and audio, then perform the same long-duration Meet/Zoom acceptance tests as the UVC backend. Handle unplug/replug and watchdog recovery explicitly.

The separate [cansik/open-opal](https://github.com/cansik/open-opal) repository offers earlier Python experiments and explicitly calls its app a proof of concept. It corroborates feasibility but is not a production-ready substitute.
