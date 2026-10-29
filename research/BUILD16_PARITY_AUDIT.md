# Build 16: shipped-code color and blur audit

This audit follows the user's request to read Composer's actual implementation instead of substituting similar effects. The target is the installed Opal Composer 2.0 build 24. Earlier feature matrices describe older implementations and must not be read as the current pipeline.

## Recovered and integrated

- Capture requests native 420v buffers. Composer's own compiled YUV-to-RGB shader maps the raw planes, preserving its unusual lack of video-range expansion. Standard Core Image decoding previously changed the tonal distribution before any adjustment.
- Bokeh, Touch Up, five custom looks, selective HSV, tint, shadows/highlights, vibrance and CLAHE execute the shipped GPU fragments or the exact embedded Metal source. Gaussian passes use the original Metal Performance Shaders parameters and original intermediate formats.
- Tone Sync now uses the original red-channel mask blend, fixing a confirmed bug where Core Image ignored the actual Rh mask and returned unchanged source. Tone Sync and standard CI photo filters use Composer's Device RGB/BGRA8 Core Image configuration. Tone Sync uses the bundled BlazeFace model and recovered weighted NMS, crop and calibration parameters.
- Tone Sync calibration runs asynchronously with immediate retries, cached correction during reload, one worker job, and generation invalidation after reset or a newer white-balance revision. Eight lifecycle checks and a suspended-worker test cover this behavior.
- Verified white-balance control completion invalidates stale Tone Sync calibration. Original native code performs a reload when `DeviceInfo.hasWhiteBalanceChanged` is true. The stock UVC implementation does not expose that original per-frame telemetry; spontaneous automatic-WB changes are not claimed equivalent.
- Apple GPUs use the original Vision request settings and R16-half mask with linear, clamp-to-zero resize. Non-Apple GPUs use the original GoogleMeets model, softmax and two surface-blur refinement passes. The latter has synthetic inference checks on Apple hardware, not an Intel live-camera acceptance result.
- Native graph order is camera module (FXAA disabled in default capabilities), Touch Up/Tone Sync/lighting/HSV, Bokeh, face-lock crop, then manual zoom. The previous pre-crop/pre-blur order was wrong.
- Face-lock uses the recovered dense-covariance Kalman calculation, native default amount and 20-frame transition. Its crop is separate from manual zoom. Crops use separate BGRA8 sampling passes.
- Native zoom labels differ from physical crop factors. The UI now preserves those exact mappings, limits and steps. Bokeh's fresh default is 7.6, with step 0.11. Old blur values retain their displayed aperture while using the native bokeh renderer.
- Touch Up UI 0–100% maps to raw 0–0.5. Pixelate uses the five original resolution-scaled levels and labels. Original presets preserve filter identity/intensity, module flags and manual values when switching to Auto.

## Verification boundary

The final integrated suite passed 122 OpalCore and 10 CameraBridge tests before universal archiving (build/build16-integrated-tests.log). Independent direct-Metal oracles report zero differing bytes for the sampled full-frame/cropped bokeh, Touch Up, custom-look, HSV, lighting, vibrance and CLAHE fixtures. These are bounded shader tests, not proof of equal live camera frames. Framing and Apple mask resize have independent coordinate/interpolation checks. Hardware control callbacks and preset round trips have state tests.

The build 16 universal archive succeeded and includes arm64 and x86_64 code plus the original shader/model resources. An Intel compiler issue with Swift Float16 was corrected by passing its exact two-byte uniform representation (`0x4253`) rather than relying on unsupported host arithmetic.

The complete Tone Sync extraction/calibration/FaceBalance/Rh-mask comparison now reports zero differing bytes at three strength/warmth pairs, including cropped output. Whole-image live equality, physical reconnect behavior, and live receiver reliability still require their own results. Fractional legacy photo-filter blending is not established: the recovered XPC intensity field has stores but no located consumer. No evidence justifies calling every control and every camera state pixel-identical.

## Evidence

- [Tone Sync full-operation oracle](tonesync-oracle/README.md)
- [Native shader oracle](native-shader-oracle/README.md)
- [Camera color boundary](lighting-followup/camera-color-boundary.md)
- [Pixelate and Touch Up mappings](lighting-followup/pixelate-touchup.md)
- [Filter identities and mode preservation](lighting-followup/filter-identities-and-modes.md)
- [White-balance calibration event](whitebalance-calibration/README.md)
- [Segmentation, model and framing audit](segmentation/README.md)

Live verification is currently blocked by the Mac lock screen. An unlock was requested; no live color-match or reconnect pass is claimed for this build. Installation and acceptance results will be appended after measurement.

## Distribution checkpoint

Build 16 universal archiving succeeded. Xcode export/upload then failed with `exportArchive No Accounts` while the Mac was locked. Notarization and installation of build 16 are pending; installed build 14 was left in place. Build 15 was notarized but deliberately not installed because its Tone Sync blend was known wrong. No build 16 GitHub binary release has been published. The camera-plug-in helper remains temporarily off from the controlled update procedure and must be re-enabled after installation.
