# Feature parity and verification matrix

**Historical matrix:** The build 17 implementation supersedes the older Gaussian, Vision-face and reconstructed-color entries below. Read [the current source and test audit](BUILD17_PARITY_AUDIT.md) first. Whole-app equality remains an acceptance question, not a claim inferred from individual shader tests.

Snapshot: October 29, 2026. “Implemented” means the source/UI provides the behavior; “tested” identifies the specific local or synthetic test scope. Neither means pixel-identical Composer output or proven reliability in every meeting client. The user excludes decorations/stickers and replacement backgrounds, but requires background blur and the other relevant camera/effect features. The latest priority is reducing visible delay.

Original-app evidence is indexed in [REVERSE_ENGINEERING.md](REVERSE_ENGINEERING.md). Deep native/shader evidence and precise Touch Up/Tone Sync equations are in [effects/README.md](effects/README.md).

| Feature | Replacement status | Evidence / remaining acceptance |
| --- | --- | --- |
| C1 stock camera capture | Implemented with AVFoundation, explicit device choice and bounded recovery | Capture format, raw-frame health and sustained USB behavior need runtime observation; recovery tests are synthetic. No automatic switch to another camera. |
| Direct C1 hardware controls | Built: lens position, autofocus, exposure/shutter/ISO, exposure compensation/lock, white balance/lock, antibanding, sharpness and denoise | Camera-free real SDK command-encoding tests pass. Manual response, RAM takeover, stop/reconnect and stock restoration remain hardware acceptance items. Physical focus values are 0–255, not calibrated distance. |
| Microphone in direct mode | Deliberate operational difference, communicated in UI | Stock C1 microphone disconnects during direct runtime. Another microphone is needed; exact device audio behavior still requires hardware validation. No claim of Composer-equivalent audio availability. |
| Background blur/Bokeh | Implemented adjustable person-aware Gaussian blur and mask smoothing | Uses Apple Vision rather than Composer’s shipped models; edge quality and bokeh response differ. Movement, hair, occlusion and mask-age acceptance still required. |
| Lighting/color | Implemented exposure, contrast, saturation, highlights, shadows, vibrance, warmth and tint | Tests exercise rendering and settings bounds; exact original slider-response/color-space ordering is not fully recovered. Sensor and digital exposure remain distinct. |
| Selective color | Eight independently adjustable hue/saturation/brightness bands | Functional rendering tests; no claim of exact Composer band overlap/interpolation. |
| Standard photo filters | Eight identified Core Image photo effects, adjustable strength | Built-in filter identities are observed in original resources. Whole-pipeline appearance still needs side-by-side comparison. |
| Custom G1/D1/Q1/X1/S1 filter looks | Recovered shader equations, independently implemented | [Native mapping and AIR evidence](filters/README.md); thirty numeric color fixtures, alpha and color-managed rendering tests pass. Fast-math, intermediate texture precision and full original pipeline comparison remain limits. |
| Touch Up | Reconstructed observed guide/high-pass/detail-protected tone-curve equations | Actual Core Image render tests cover guide, curve, amount, masks and opacity. Original MPS Gaussian vs Core Image implementation, intermediate quantization and mask model can differ. |
| Tone Sync | Reconstructed skin extraction, face crop, KMeans/YIQ calibration and `CIFaceBalance` blend | Native evidence and render tests exist. Apple-private filter capability is checked; missing support reports an error. Real-face/color-managed comparison and OS availability remain limits. |
| Zoom/mirror | Implemented processed-frame crop and mirror | Rendering tests; exact original crop/framing defaults remain unverified. |
| Face-lock | Implemented Vision face tracking/framing | Tracking model, face selection and physical autofocus/exposure coupling are not established as identical to Composer. |
| Recording | H.264 video and optional AAC microphone; explicit file destination | Synthetic record/decode and concurrent-finalization tests pass. Bounded async frame handoff; microphone device behavior and long A/V synchronization need live testing. |
| Short loops | Bounded disk-backed recording, hold-to-record/release-to-play and looping | Tests cover scene advance, wrap boundaries, blocked/failed decoder and stop during preparation. Poster/last recorded frame is held on decoder failure; live feed returns only on explicit stop/clear. |
| Presets | Own JSON with image/sensor settings, thumbnails and management; partial original `.opalPreset` package import/export | Observed lighting/color mappings and unknown-field retention covered by6 tests. Unsupported fields are preserved/reported. Composer-side exported-package acceptance and exact-look compatibility remain unverified; see `PRESET_INTEROPERABILITY.md`. |
| 360p / 720p / 1080p / 1440p / 4K | Explicit resolutions in capture, effects and virtual output | Rejects undersized input rather than silently claiming genuine 4K. Actual camera/consumer negotiation and sustainable processed FPS require runtime verification at each size. |
| Virtual camera | CoreMediaIO extension, immutable opaque frame handoff, host-clock pacing | Frame transport/ownership/opacity tests pass. Signed build exists; active extension, multiple consumers, browser and Meet/Zoom receiving-side acceptance must be recorded separately. |
| Preview latency | Direct Metal pixel-buffer renderer; latest frame, one queued redraw, at most two GPU commands; thumbnails separated | Build checked. This reduces avoidable conversion/UI work; measured capture-to-preview latency and segmentation bottlenecks remain the basis for performance claims. |
| Histogram/zebras | Implemented preview aids | Synthetic analysis tests; these overlays are not meeting output. |
| Automatic output resolution / pause-on-no-consumers | No claim of Composer lifecycle parity | Explicit format and bounded recovery are implemented. Automatic device/client-demand policy is a separate parity gap. |
| Replacement backgrounds | Excluded from product UI by user request | A background-image property remains in core settings; it is not offered as a supported requested feature. |
| Decorations/stickers | Excluded by user request | No vendor assets or face-attached sticker system copied. |
| Zero flicker | Not established | Opaque complete buffers, bounded queues, buffer lifetime guarantees and stale-frame handling address plausible defects. The original white-box/opacity flicker has not been causally reproduced and diagnosed. |

## Runtime acceptance boundary

[webrtc-check.html](../scripts/webrtc-check.html) provides a local same-browser WebRTC encoder/decoder check with no remote peers or ICE servers. It reports actual dimensions, codecs, decoded/dropped frames, jitter and timestamps; it is not an actual Meet/Zoom call. Permission and capture are explicit. Successful local loopback, by itself, does not prove network-call or remote-receiver reliability.

Record hardware/backend, selected format, enabled effects, frame age, segmentation/processing time, fresh-vs-repeated output rate, and receiving-side artifacts for each live run. Do not count repeated complete frames as newly processed frames or treat a smooth local preview as proof of meeting output. Direct C1 takeover tests and measured performance results should be appended with their actual outcomes rather than changing pending items speculatively.
