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
