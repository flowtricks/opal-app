# C1 enumeration audit — 2026-10-29

The main agent observed a transient UVC capture stall and missing C1 in `system_profiler`. During this investigation, `ioreg -p IOUSB -l -w 0` showed the physical Opal C1 present, active at 5 Gbit/s, stock vendor/product `03e7:f63d`. Registry property `UsbExclusiveOwner` named PID27709 `OpalCameraUVCSer`; `ps` resolved it to the installed Composer's `OpalCameraUVCService.xpc`, started at 14:30:56 local time. A subsequent `system_profiler SPCameraDataType` showed physical Opal C1 again. No reset, service termination, open, or takeover was performed during this investigation.

The initial C1 backend enumeration used `libusb_init`, `libusb_get_device_list`, descriptor reads, `libusb_open`, and close. No explicit reset, configuration change, interface claim, SDK device discovery, or `c1_open` call was made by the implementation agent's runtime harness. However, inspecting the exact bundled `libusb-luxonis` 1.0.24-cmake archive revealed that Darwin `darwin_open` internally calls `USBDeviceOpenSeize`. Its discovery descriptor path also attempts seizure and can unsuspend devices or set configuration when encountering malformed descriptors. Consequently the initial enumeration was not guaranteed passive, and it cannot be excluded as a contributor to the transient disappearance. The available snapshots do not prove a cause; the stock Composer service was also active.

Evidence source: `.build-tools/hunter/_Base/Download/libusb-luxonis/1.0.24-cmake/2d79573/b7e4548958325b18feb73977163ad44398099534.tar.gz`, member `libusb/os/darwin_usb.c` (repository directory prefix omitted). SDK `vendor/depthai-core/src/utility/Initialization.cpp` has its shared-library preload initializer commented out. The control regression harness only encodes messages; it does not call device discovery or camera opening.

## Correction and verification

`stockCameras()` now uses `IOServiceGetMatchingServices` and `IORegistryEntryCreateCFProperties` to read cached macOS properties. It matches exact VID, stock PID, product name, and serial number. It never opens USB device handles, sends USB requests, or invokes SDK discovery. Both Refresh and the identity check preceding explicit Start use this implementation. Bridge undefined symbols confirm there are no `libusb_*` function imports. DepthAI still depends on libusb for explicitly requested native capture.

After rebuilding, the passive enumeration harness found one `Opal C1`, PID `f63d`; `system_profiler` still listed it immediately afterward. C1 control tests passed, and release `swift build --product OpalStudio` passed. Hardware capture/takeover has not been tested by this agent.

A separate start-order race was fixed: `C1Controller.start` now waits for `CameraEngine.stop(completion:)` to finish stopping the AVFoundation session before scheduling the native open. Cancellation/generation guards prevent a queued start from proceeding after Stop.

## First direct-mode runtime attempt

The parent agent explicitly started direct capture during the later live test. The camera reached `Luxonis Bootloader` (`03e7:f63c`) and the app ultimately reported `Failed to find device after booting: X_LINK_DEVICE_NOT_FOUND`. The process sample at `build/c1-start-sample.txt` was captured after the operation had completed; it contains no blocked C1 constructor stack and therefore does not identify a hanging function. Subsequent passive IORegistry and `system_profiler` reads showed the original C1 back in stock `03e7:f63d` UVC mode. This agent performed no recovery/reset command and no flash operation.

The original single “Loading runtime” status obscured whether the SDK failed while connecting to the bootloader or after uploading firmware. Source inspection shows both can use the same XLink error text. SDK defaults are 15 seconds per boot wait and 5 seconds per connection wait; multiple stages accumulate, and Stop queues cleanup after the synchronous constructor rather than interrupting it unsafely.

The bridge was revised to prewarm runtime resources and construct the graph before leaving stock mode, handle both stock XLink states through an explicit bootloader-to-ROM path, resolve the exact selected identity again at each transition, and report stage/version information. ROM discovery polling was reduced to 25 ms. This rebuild and camera-free command tests pass. Successful hardware streaming is **not** established by these changes; the next controlled direct-mode attempt must verify the actual transition, frames, controls and restoration.


## Second failed attempt and camera-free handoff correction

The later direct-mode attempt reported failure at **locating the selected C1 in USB ROM mode**. The parent observed `03e7:2485` (Myriad X ROM) after failure; this proves a USB personality transition occurred, not that the SDK retrieved the selected identity or that a runtime started. The user subsequently reconnected USB and restored stock mode. The saved process sample does not cover the failed call; a complete rejected-device/status trace from that attempt is unavailable. Do not infer a changed MxID, missing permissions, or a watchdog race as the proven root cause.

A subsequent source audit found two concrete avoidable constraints in the wrapper. They are corrected without a camera test:

1. The wrapper unconditionally requested USB ROM. Pinned SDK `DeviceBase.cpp` lines 771–803 instead uses configured `bootMemory` for bootloader versions ≥0.0.12, and ROM only for older versions. The wrapper now validates the selected stock camera, requests stock→bootloader, reacquires that exact hardware ID, then lets the SDK own the version-aware RAM handoff and firmware configuration. It does not invent a bootloader version or issue flash writes.
2. The SDK's legacy ROM search (`XLinkConnection.cpp` around 419–432) treats a retained USB `name` as a strict constraint. The wrapper now clears that transient path on the verified bootloader `DeviceInfo` while retaining its exact MxID, USB protocol, platform and bootloader state. Later searches still require that MxID; no first-device or sole-device fallback is introduced. This matters because the XLink path is bus/port-based and the camera may cross USB2/USB3 topology during handoff.

The removed separate `findExact(UNBOOTED)` loop is no longer a gap between the ROM request and SDK startup. The SDK still has synchronous boot/connect timeouts and its own loader cleanup; this correction is not a proven fix for the observed device or proof of automatic recovery.

### Why the generic ROM serial is not enough

The exact XLink source [usb_host.cpp](c1-sdk-source/usb_host.cpp), from pinned archive commit `82839cb04f2102177fad926fb8f7fcf7b4093cb1`, retrieves an unbooted Myriad's MxID by sending a small RAM helper, reading nine bytes, then ending watchdog protection. It does not use the generic ROM USB serial. Thus even `getAllConnectedDevices` in ROM state actively communicates; it is not a safe passive diagnostic. [usb_mx_id.cpp](c1-sdk-source/usb_mx_id.cpp) contains this public helper and an expiring path-keyed cache. Source hashes are in [manifest.json](c1-sdk-source/manifest.json). These sources were extracted for inspection, not executed in this audit.

### Stock UVC focus assessment

No verified control-only route for manual C1 focus was established. macOS AVFoundation does not expose the iOS-style custom lens-position setter on macOS. Generic UVC `FOCUS_ABSOLUTE` and `FOCUS_AUTO` selectors exist, but their presence does not prove C1 firmware accepts them. Published first-party experiment notes from [decomposer](https://github.com/fidecastro/decomposer/blob/main/docs/camera-notes.md), sections “Standard UVC controls” and subsequent corrections, report read-only autofocus, inactive manual focus, and unsuccessful extension-unit writes on a different C1 running firmware 4.10. That is supporting evidence, not a measurement on this user's unit. Earlier speculative hybrid-control claims in that same document were later retracted; do not cite them as proven functionality.

The shortest honest stock-UVC assessment would be narrowly scoped UVC GET_INFO/GET_CUR for the advertised focus controls followed by an explicitly coordinated response test only if writable. Such probes can require USB opens on macOS, so none were run here. Broad XU write sweeps or a guessed vendor protocol are not justified. A reliable manual lens slider still depends on successful native runtime or a separately recovered control protocol.


## Latest live result after correction

The corrected SDK-managed handoff was tested on this camera and still failed: `Failed to find device after booting, error message: X_LINK_DEVICE_NOT_FOUND`. IORegistry subsequently showed the original Opal C1 identity (product0xf63d and its original serial), so this attempt recovered to stock automatically. No flash write was requested. The wrapper defects were corrected, but this result does not establish the remaining root cause or support a claim that manual physical controls work. Stock capture was restored afterward.

## Stock UVC focus probe — October 29, 2026 follow-up

The parent agent stopped camera applications and ran the new descriptor-driven, non-seizing IOKit helper (`scripts/c1-uvc-focus.cpp`). It resolved the selected stock C1's actual VideoControl camera terminal 1 on interface 1. Absolute focus was advertised with GET_INFO=3 (GET+SET, disabled bit clear), GET_CUR=130, GET_MIN=0, GET_MAX=255, GET_RES=3. Focus Auto was advertised with GET_INFO=1 (GET only), GET_CUR=1. No autofocus write was sent.

Because absolute focus explicitly reported enabled+writable despite the read-only autofocus switch, the parent ran the narrowly bounded `--test-focus 90` operation. SET_CUR returned `0xe000404f`; the helper's attempted restoration to the captured original 130 returned the same error. A subsequent read-only probe confirmed current focus remained 130, with the same capability flags. The installed SDK `IOKit/usb/USB.h` defines this error as `kIOUSBPipeStalled` (“Endpoint returned a STALL PID”). Thus GET_INFO alone was misleading on this unit: the actual absolute-focus SET was rejected. No lens motion was established, no control was force-enabled in the shipping app, and no vendor request, USB reset, interface seizure, or firmware handoff was used.

The helper requires an exact serial and exact stock VID/PID/name match. It parses the active configuration's VideoControl interface and camera terminal control bitmap, refuses ambiguous/malformed terminals, never claims an interface, and only writes when explicitly passed --focus/--auto/--test-focus and the addressed control advertises GET+SET+enabled. Test mode restores the exact captured initial value even when the camera's own current value does not lie on its reported step. Descriptor-only self-tests compile/pass without hardware. The failed runtime write establishes a limit; the helper is not a working focus implementation.

Fresh REA Objective-C metadata for the original UVC service is in `c1-uvc-dispatch.json`, Evidence `ev_4762b53ccae7ca1d765cb8a385142f13830c45d80c05cf084e233987e53992ee`, artifact SHA-256 `0b44e408382fb210ea65a32e1f9bbaa8ad5977e60072af4c5d87dee844e8f0a7`. It resolves `UVCCameraDevice setFocus:` at 0x100006958, `UVCIntControl setCurrent:` at 0x100005ae4, and `UVCControl setDataWithValue:length:` at 0x100004754. Supplementary ordinary LLVM disassembly is in `c1-focus-disassembly.txt` and `c1-uvc-control-disassembly.txt`: initialization selects two-byte control 6 and one-byte control 8 using the terminal/interface arguments; the write function issues 0x21/SET_CUR with selector in wValue and terminal/interface in wIndex. This is the same standard protocol shape as the probe, not evidence of a separate stock-vendor focus protocol. The separate original DeviceService includes DepthAI camera-control symbols, but active original backend/lens response requires runtime observation.


### Composer manual-focus follow-up: stock UVC route confirmed

The parent then visually tested the original Composer with background blur reduced to f5.7. Its focus control changed the distant walls/blinds/chandelier from crisp at 2.0m to strongly defocused at 0.1m, immediately. At that time the original processes included OpalCameraUVCService and OpalCameraVideoService, no DeviceService was found, and USB remained stock PID f63d. This contradicts treating the first rejected absolute write as proof that stock manual focus is impossible; it only establishes that the tested absolute-only sequence failed while Focus Auto read back 1.

A closer static trace of the same REA UVC evidence found an omitted sequence dependency: `UVCCameraDevice setFocus:` at 0x100006958 first reads cached autofocus state and, if enabled, calls `UVCBoolControl setIsEnabled:false`, then maps/writes absolute focus. `UVCBoolControl setIsEnabled:` at 0x100003d54 unconditionally attempts its configured one-byte SET through `setDataWithValue:length:` and caches only on success. Its capability initialization treats any nonzero GET_INFO as capable, not the GET+SET mask. Thus Composer can attempt the autofocus write even when this firmware reports GET_INFO=1. Saved supplement: `c1-uvc-autofocus-disassembly.txt`.

The explicit diagnostic `--test-composer-focus INTEGER` was added to reproduce precisely this bounded C1 sequence. It still requires selected exact stock identity and advertised/readable AF, plus verified absolute capability/range. It sends AF=0, requires zero readback, sends one absolute value, reads it, then always attempts both original absolute and original AF restoration. Generic --auto remains capability-gated. This diagnostic was compiled and descriptor-only self-tests passed; no hardware was opened by the implementation agent.

### Native-runtime comparison, before stock UVC was verified

Fresh REA metadata for the shipped DeviceService is in `c1-device-dispatch.json`, Evidence `ev_c09be6d47433415414ce52d7dd3ee622fc643b0e39a454f91cecbe36ee168e61`. `ControlQueueManager setFocus:` (0x100030b68) calls the public DepthAI `CameraControl::setManualFocus(uint8_t)` and `setAutoFocusMode(OFF)` and sends through its own input queue. `c1-device-focus-disassembly.txt` records this; the command encoding matches our bridge, but this service is not the one observed handling the successful stock focus test.

REA metadata for the shipped `libdepthai-core.dylib` is in `c1-original-sdk-metadata.json`, Evidence `ev_243f87bf38e165df90d4adc9519f13e09292afc1073bcc44e654781cb4dc5641`, SHA-256 `0a0bbd9d60ce95c789351783956549d2406dea982ef0047c526f76ede948f05d`. Strings declare 2.15.1 and firmware e2929eb3993d759114d7084074a0eec845c12b45. Supplementary disassembly of DeviceBase::init2 confirms the same version-aware bootMemory/ROM branches; XLink reconnect fixes its old descriptor-name suffix and searches expected state. Our newer v2.30.0 uses firmware a62b2ccb0bc493c2fb41694cb81c08887be24c52. Public v2.15.1 tag resolves to b6e5f3bc9ac1473c0a91012611a6f7f9d97c384d and declares different firmware 2bebad51c15c2e8961899a29b93b93f2409d8464; it is not a proven exact substitute for Composer's fork. Selected public files are under `c1-sdk-2.15.1/`. No runtime was changed or uploaded during this comparison. This remains a compatibility lead, not the proven cause of the failed native handoff, and is unnecessary if the stock UVC path can be reproduced.


### Stock focus sequence succeeded; production control path

The parent's next bounded test started with absolute142/AF0, sent AF0 then absolute90, read back absolute110 (firmware clamp), and restored exact142 plus AF0 successfully. With Opal Studio AVFoundation capture active, subsequent raw255 and111 writes were accepted with matching readback and visibly different near/far optical focus. Non-seizing control opens coexisted with capture. No native-runtime handoff is needed for this tested focus path.

`Sources/C1API/StockC1Control.cpp` now implements a separate standard-UVC focus control channel, linked directly into C1API. It requires exact stock C1 identity, discovers camera-terminal/processing-unit entities from active descriptors, uses bounded non-seizing IOKit requests, keeps all control work outside rendering, and returns actual clamped focus readback. The explicit AF GET-only compatibility exception is limited to this verified C1 path. GET_RES is intentionally not used for quantization: both the original142 value and successful111/255 tests establish that the advertised step3 is not a reliable constraint on accepted settings. The Swift controller permits at most one in-flight focus operation and one latest pending target; disconnect completion waits for handle release. Closing releases the handle without resetting camera state.

### Exact Composer distance conversion

Supplement `c1-focus-distance-disassembly.txt` isolates main executable0x100298898 (focus update) and0x1000f7f58 (sensor capability selection). Read-only constants at0x100661c78/c80/c88 are0.008809951,0.1152665,113.5080092953979. The native code computes:

`raw = min + ((0.1152665 / (meters * 0.008809951) + 113.5080092953979 - 120) / 135) * (max-min)`

then truncates to integer before the UVC setter. Default capability data at0x100659bb0 contains focus endpoints120/255; named IMX378 data at0x100661c50 uses120/206 and IMX582 at0x100661c70 uses110/206. The live original preference `OCFocus` was0.45599999999999996 while its rounded UI read0.5m; default calibration gives142.20, truncated142, exactly matching the parent's observed lens readback. The default profile is therefore strongly corroborated for the tested stock UVC route. This is not a claim that all C1 sensor profiles share the same calibration. Static conversion helpers in StockC1FocusController use the tested fallback and constrain UI distance0.1...2.0m.

### White balance control preparation

The same production channel adds descriptor-driven Processing Unit white balance temperature (selector0A, bitmapbit6) and automatic temperature (selector0B, bitmapbit12), with GET_INFO gating. It follows the separately recovered Composer sequence of disabling auto, clamping integer Kelvin to device min/max, writing, and reading back. No AF-style GET-only exception is applied to white balance. `scripts/c1-stock-control-test.cpp` provides read-only capability/state inspection and an explicit `--test-wb` operation that attempts temperature and auto restoration on both success and failure. It was compiled but not run by this agent. Runtime acceptance remains the parent's test requirement.


### Integration verification and white-balance probe limit

The parent ran the new production-channel diagnostic while the installed camera was active: focus read130/AF1, then a white-balance GET failed with endpoint STALL before any WB SET. The diagnostic now includes entity, interface, selector, request and length so a follow-up read can identify the unsupported query. Production `whiteBalanceAvailable` remains false after failed capability/state inspection; it retains software temperature and AVFoundation WB lock behavior. It never suppresses software warmth based solely on an advertised descriptor. The optional hardware bypass turns on only after a confirmed manual WB response.

StudioModel integrates stock controls on camera startup and selected-camera changes, closes the channel before backend changes/shutdown, restores persisted focus after the first migration, and only synchronizes successful operation/readback events into settings. Initial connection readbacks cannot race and overwrite saved desired focus. ComposerView observes controller availability, exposes the0.1...2.0m focus slider and Manual→Auto action, and shows control errors. CameraEngine no longer resets USB-managed focus on unrelated adjustments. The UI/preset settings retain requested warmth; hardware-confirmed WB bypass only changes the processing copy.

Verification: C++14 syntax checks and standalone Swift typechecks passed; `swift test` passed56 OpalCore plus10 CameraBridge tests, including3 new calibration tests matching original OCFocus. Log: `build/stock-c1-integration-tests.log`. No signed-app install, hardware open, or UI action was performed by this implementation agent. Parent must verify the newly packaged app's sandboxed control connection, lens response, Auto reset, and reopen persistence before release.

### Build 11 replug follow-up (2026-10-29)

The integration owner observed repeated USB disappearance/re-enumeration roughly 16.7 seconds apart after replug with Studio running, eventually showing Luxonis Bootloader. This does not establish a stock-control request as the cause. Static audit found no reset, firmware boot, configuration change, or periodic retry in `StockC1Control`; destruction only closes/releases the non-seizing IOKit device interface.

A separate definite lifecycle bug was found: capture kept `isRunning=true` during physical disconnect, while stock-control invalidation depended only on `isRunning` and selected ID. Consequently a same-serial reconnection could retain its detached IOKit handle. The controller now observes physical C1 disconnect, immediately invalidates queued control work, and closes the handle on its worker queue. A successful capture restart reconnects with a fresh handle. Cancellation also suppresses an error-follow-up read after detach; an already executing bounded USB request is allowed to finish before close.

Connection no longer automatically probes optional physical white balance. This camera consistently advertises the control but stalls PU selector0x0a GET_CUR (2 bytes), including after a power cycle. Repeating that unsupported probe on every USB reconnection is unnecessary; software temperature stays active. The explicit diagnostic API remains available. These changes compiled with `swift build --product OpalStudio` (`build/stock-c1-replug-build.log`). No hardware actions were performed by this audit; replug stability and persistence still require installed-build validation by the integration owner.
