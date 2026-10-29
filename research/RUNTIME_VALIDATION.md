# Local runtime validation

October 29, 2026, this Mac and its connected Opal C1. These are bounded local observations, not a guarantee against all flicker or an exact Composer parity claim. No camera images were uploaded or saved for these checks.

## Performance changes

- Live preview renders retained pixel buffers directly with Metal, with at most two GPU commands and one pending redraw. Histogram/preset thumbnails run separately at 3 Hz.
- Effects publish completed frames immediately. A bounded watchdog repeats on capture gaps; an independent app-side 30 Hz timer no longer delays every fresh frame.
- Virtual-camera input queue capacity is one, with reads independent of the output tick. Immutable copies and opaque alpha remain enforced.
- Full-rate person segmentation remains enabled. Tone Sync calibration is cached; blur quality was not reduced.
- AVFoundation output dimensions are explicit. This fixes an observed 4K selection that had still delivered 1080p buffers.

## Observed checks

| Check | Result | Scope |
| --- | --- | --- |
| Signed app and extension | Native Release build and deep strict signature verification pass; extension version 2 activated/enabled | Local developer signing, not a notarized public release |
| 1080p C1 with blur | 499 captured, processed and emitted; zero drops, failures or repeats. Snapshot: capture queue 1.6 ms, capture timestamp → processed 16.3 ms, processed → output 0.0 ms | Approximately 17 seconds after immediate-emission change; not glass-to-glass latency |
| 4K C1 with blur | 171 captured/processed, zero drops/failures, one startup repeat; snapshot 19.3 ms capture timestamp → processed, 0.0 ms output wait | Actual 3840×2160 buffers after explicit output-size fix |
| 1080p consumer integrity | 519 received frames, zero alpha/timestamp/dimension faults; largest gap 34.2 ms | Alpha scanned 4 times/second; live camera scene |
| 1080p synthetic transport | PASS: 451 frames, zero faults, 30.0 fps, 29.9 color changes/second, largest gap 34.6 ms | Every pixel checked; isolated consumer; no camera images |
| 4K synthetic transport | PASS: 451 frames; zero pixel, timestamp or dimension faults; 30.0 fps, 26.7 color changes/second, largest gap 38.1 ms | Every actual 3840×2160 pixel checked after receiver-size fix |
| Chrome local WebRTC | 761 decoded frames, 30 fps, zero decoder drops, packet loss or freezes; mean jitter-buffer delay 8.638 ms | 1080p source; Chrome adapted encoded receive resolution to 540p/720p. Same-page local peers, no remote service |

The first two synthetic runs overlapped a second consumer changing the camera resolution. Their old inspector counted changed dimensions as corruption. An isolated run passed. Diagnostics now separate pixel faults, timestamp faults and format changes; requested receive dimensions are explicit. No failing run is silently counted as a pass.

macOS initially failed to launch the updated extension during an upgrade race (`Operation already in progress`). Toggling the existing approved extension off/on and relaunching the host restored discovery. Approval was retained; the new extension was confirmed running from its version-2 system location.

## Direct C1 controls

The first direct-runtime start failed with `X_LINK_DEVICE_NOT_FOUND` after boot. The camera returned to stock mode without a recovery command or firmware flash. The bridge was then changed to explicitly stage bootloader → ROM, preload runtime resources, rediscover the same camera identity, and report each failure stage. Successful hardware streaming and control response remain pending the corrected build's test.

## Remaining boundaries

Remote Meet/Zoom receiver behavior, long-duration calls, proprietary model/slider parity, original preset compatibility and custom filter looks are not established by these tests. See [FEATURE_PARITY.md](FEATURE_PARITY.md). Output clocks and software timing exclude sensor exposure/readout, display presentation, network and remote-client delay.

## UI/functionality pass and extension version4

After installing the expanded-format extension (0.1.0/4), macOS reported activated/enabled but the host initially retained stale discovery state. Restarting the already-approved extension and host restored connection. No new signing authorization was needed.

Generated-frame receiving-side checks, each15seconds:

| Requested size | Received | Pixel faults | Timestamp faults | Size changes | FPS | Color changes/s | Largest gap |
|---|---:|---:|---:|---:|---:|---:|---:|
|1920×1080|452|0|0|0|30.1|30.0|41.9ms|
|2560×1440|452|0|0|0|30.1|30.0|39.9ms|
|640×360|452|0|0|0|30.1|30.0|40.0ms|

A live1080p stock-C1 run with Bokeh enabled reported2045captured/processed frames,0capture drops,0processing failures,4repeats,1.6ms capture queue,16.5ms input→processed and5.1ms latest processed→output wait. Its separate virtual-camera receiver inspected281frames with0timestamp,0alpha and0dimension faults; largest delivery gap44.0ms. These are local samples, not camera-to-remote-call latency measurements. Version4 steady transport log samples showed sink means3.26–3.66ms and latest output age7.73–12.88ms; an earlier startup sample was37.39ms.

Live camera-only recording through the rebuilt Record window successfully saved and decoded87frames at1920×1080 over2.907seconds, with0non-monotonic timestamps. Audio was off for that check; no microphone/screen capture claim follows. The disposable test clip was removed after validation; the text log is `build/live-recording-check.log`.

The latest direct C1 test failed at the SDK-managed RAM handoff with `X_LINK_DEVICE_NOT_FOUND`. Stock USB identity returned automatically (Opal C1, product0xf63d); no flash write or further physical reconnect was needed. The installed app was restored to stock capture,1080p and its pre-test effect values. Physical focus and direct sensor-control parity remain unresolved.

## Notarized universal build 11 — 2026-10-29

The app, camera extension and camera-arrival helper were archived for `arm64` and `x86_64`, signed with Developer ID Application for team G766RX9X84, submitted through Xcode, and exported after Apple's notarization completed. `stapler validate`, strict deep code-signature verification, and Gatekeeper assessment all passed. The ZIP was extracted into a separate directory and those checks passed again. The signing profile uses `ProvisionsAllDevices`; installation is not limited to registered development Macs. Intel runtime behavior has not been exercised on this Apple Silicon host.

Installed build 11 restored live C1 capture. Its enabled focus-distance slider physically changed focus at the 0.1 m and 2.0 m endpoints without restarting capture; Auto was restored afterward. Temperature hardware probing returned STALL for entity3/interface1/selector0x0a/GET_CUR/length2, so the application correctly retained software temperature correction. This is not a verified hardware-white-balance implementation on this unit.

At a local 720p loopback checkpoint, capture/processing/output counts were all 2,789, with zero capture drops, processing failures, recovery attempts, interruptions, or repeated frames. The independent virtual-camera consumer had received 2,115 frames with zero invalid timestamps, alpha-fault frames or unexpected dimensions; 265 full alpha scans, largest observed delivery gap 46.8 ms. The snapshot reported 12.7 ms input-to-processed time and 1.8 ms processed-to-output; these are pipeline measurements, not glass-to-glass latency. The consumer test was stopped after this check. This does not establish sustained Meet/Zoom behavior.

During the earlier interrupted-camera reports, IORegistry identified the C1 as Luxonis Bootloader and both original Composer and Studio were running. Original Composer's plug-in-startup setting was visibly enabled; it was turned off through Composer's General settings, then Composer was quit. After a physical power cycle the camera returned to stock Opal C1 and stayed there during build11 verification. This establishes the observed recovery and launch conflict, not the exact cause of the camera entering bootloader mode.

After replacing the Apple Development build with Developer ID signing, the first helper registration hit a macOS launch-constraint cache rejection. Unregistering that one helper and registering it again through Studio's General settings resolved it: launchctl reported parent build11, running, PID65144; its log confirmed it was watching C1 arrivals. Login registration was similarly refreshed. No global BTM reset, security bypass or reboot was performed. Final physical replug validation is recorded separately when completed.

Private release: https://github.com/flowtricks/opal-app/releases/tag/v0.1.0-build11
ZIP SHA-256: `2e17e533624ea6159efdc42501f2287baf2e055fcf8888195419eb9a13b68b59`.


## Build 11 reconnect failure and build 12 corrections — 2026-10-29

The final physical replug check on build 11 failed: the same Studio process repeatedly lost capture while IORegistry alternated Opal C1 and Luxonis Bootloader. The original Composer app/helper were off, and Studio's arrival helper logged reuse of the existing process. Camera Off stopped the enumeration loop; the stock C1 then retained the same registry entry. This disproves treating the earlier original-app startup conflict as the complete explanation. Build 11's successful steady-state loopback did not establish reconnect reliability.

Build 12 serializes capture configuration, cancels stale configuration/control operations on detach, waits for physical reconnection, and starts the first-frame watchdog grace after the blocking camera start completes. It removes the automatic optional white-balance probe known to stall on this unit. The virtual-camera bridge lifecycle now belongs to StudioModel and stays connected during requested-source interruptions. Active capture holds a scoped user-initiated latency-critical ProcessInfo activity so macOS App Nap does not throttle background video delivery; it still allows system idle sleep.

Loading now shows only the original alpha-bearing C1 movie over the app canvas, without status text or a Start button while capture is requested. Native AVFoundation inspection confirms premultiplied alpha and transparent corners; the installed movie's SHA-256 equals Composer's resource. Exact original SwiftUI loader dimensions have not been recovered.

Build 12 passed 60 Core and 10 Bridge tests, universal archive, Developer ID signing, Apple notarization, strict signature verification, stapler validation and Gatekeeper assessment. It was installed cleanly and its camera-arrival helper re-registered successfully under parent bundle version 12. Runtime reconnect/background results follow after validation.

Installed build 12 background check: NSRunningApplication independently reported PID 74799 `hidden=true active=false`. From the post-hide checkpoint to the final hidden checkpoint, the independent virtual-camera receiver advanced from 79 to 1,573 frames (about 50 seconds at 30 fps), while capture advanced from 1,210 to 2,700. Capture drops, processing failures, recovery attempts, interruptions, repeated frames, invalid timestamps, alpha-fault frames, and unexpected dimensions all remained zero. Maximum consumer gap over the run was 73.4 ms. This verifies continued local 720p delivery while hidden on this Mac, not sustained Meet/Zoom performance or every resolution.

The distributed ZIP was separately extracted and passed strict deep code-signature verification, stapler validation, and Gatekeeper assessment. Build 12 ZIP SHA-256: `2afb98799b9d1f0aa3a038b79b05b1ac3925f753d3d69d8c228f2a6364785d35`.
