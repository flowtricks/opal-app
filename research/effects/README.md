# Skin effects reconstruction evidence

Inspected 2026-10-29 with the installed `reverse-engineer-anything` skill and pinned `rea-agents@6.8.0`. Original application files were read only. No vendor binary, model, shader library, or decompiled implementation is linked into Opal Studio. Core implementation is an independent translation of the observed math using system Core Image filters.

## Artifacts and tools

- Original XPC executable: `/Applications/Opal Composer.app/Contents/XPCServices/OpalCameraVideoService.xpc/Contents/MacOS/OpalCameraVideoService`, SHA256 `c167c72bd8fbf228072ae94eda0a959fe58f7beb7de344ceb7fd29a1e8ec6e6c`.
- Analysis-only arm64 slice: `.analysis-tools/targets/OpalCameraVideoService-arm64`, SHA256 `544b31ac84ac62e3a3572f89c9ff41ad5d851255d954de39f45ddcae1ff79e83`. Slice made with Apple `lipo`; original unchanged.
- Ghidra 12.1.4 official release archive SHA256 `ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db`; native arm64 decompiler built from that release's source using Xcode. Temurin 21.0.13+9 official archive SHA256 `bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a`. Tools remain in ignored `.analysis-tools/`, with no global install or configuration.
- REA native session exported 33 evidence records to `rea-evidence-bundle.json`, then closed (`export-receipt.json`, `close-receipt.json`). Ephemeral Ghidra project discarded.
- The XPC's `Resources/default.metallib` contains ordinary LLVM bitcode wrappers. Local llvmlite 0.50.0 decoded these without executing the vendor kernels. `air/manifest.json` records exact library and module hashes/offsets. Relevant modules: 31821 (guide), 36173 (Touch Up composite), 42141 (skin extractor).
- Upstream MetalPetal reference, only for understanding the spline: https://github.com/MetalPetal/MetalPetal/tree/f9b78897bd4214bb097f352a1bde0a4f4a1e2ddb . No upstream source was pasted into production code.

## Touch Up: observed math

`MTITouchUpFilter::init` at `0x100009968`, `outputImage` at `0x100009adc`, and `defaultToneCurveControlPoints` at `0x100009594` are in the corresponding JSON evidence. Native wrapper defaults at `0x10000d99c` override the filter's amount to zero and retain radius 8. Original MPS blur kernel uses sigma=radius and clamp-to-edge (`gaussian-sigma.json`).

1. Guide is overlay blend of G/2 and B/2; for bounded ordinary RGB it is G×B/2.
2. Blur the guide with Gaussian sigma 8 and calculate guide−blur+0.5.
3. Apply three self-hard-light contrast passes, clamping each: `x<0.5 ? 2*x*x : 1-2*(1-x)*(1-x)`.
4. Detail protection is `clamp((x−0.29411765933036804)×2.865168571472168,0,1)`.
5. Apply the 256-entry, 8-bit natural cubic tone curve with points (0,0), (120/255,146/255), (1,1), linearly sampling between entries.
6. Blend source→tone curve by user amount, then blend that result→source by detail protection. Finally blend source→result by the person mask. Alpha is preserved and final camera output is opaque.

`SkinEffects.swift` implements these equations, replacing the earlier unrelated noise reduction filter. The guide/math/LUT, masks, zero amount, and background protection have rendering tests.

## Tone Sync: observed algorithm

The previously unknown transform is **Apple's built-in CIFaceBalance**, not a guessed skin-hue slider. The name is constructed as Swift small-string immediates in native instructions at `0x100049abc` (full procedure `0x100049a68`). Native parameters are:

- `inputStrength = 2 * amount`;
- `inputWarmth = warmth`, default 0.5;
- `inputOrigI` and `inputOrigQ` from calibration;
- result blended with the original using the person mask.

Native defaults (`skin-defaults.json`) are amount=0, warmth=0.5, averageMethod=0 (KMeans), I=Q=0, needsReload=true. Calibration is triggered until I/Q are valid and again on explicit reload; the native code schedules this work asynchronously. Our serial effects implementation performs a bounded calibration attempt and retries at most once per 30 processed frames, then caches it until explicit reload/reset.

Calibration:

1. Skin extractor rejects person mask below0.5; clamps RGB to0.0001...0.9999 for calculations; uses gray=(R+G+B)*0.33333, inversegray=3.000030040740967/(R+G+B), red saturation=max((R−gray)/(1−gray),(gray−R)*inversegray), and skin score=clamp(min(R−G,2G−B)*4*(1−redSaturation)*inversegray,0,1). Pixels with score>0.3 retain original RGBA; others become transparent.
2. Face bounds are inset by7.5% width on each side and15% height at top/bottom (`0x100049198`).
3. CIKMeans uses one cluster, ten passes, nonperceptual mode, and seed RGB(0.6,0.5,0.4). Its output is read as 8-bit RGB (`0x10004a978`).
4. I=0.5959R−0.2746G−0.3213B; Q=0.2115R−0.5227G+0.3112B. These exact native constants are used in our implementation.
5. CIFaceBalance is invoked with those values and blended by the person mask (`0x1000493d4`).

Verified CIFaceBalance availability on this Mac. It identifies itself as `CICategoryApplePrivate`; availability on every macOS version is not promised, so the app exposes a capability check and error instead of silently substituting another effect. This is unsuitable for assuming App Store eligibility without a separate API review.

## Remaining parity limits

These are reconstructed effect algorithms, **not proof of identical camera pixels**. Opal Studio uses Apple Vision face/person models while Composer ships BlazeFace/GoogleMeets models. Face boxes and mask edges therefore differ. Opal Studio's Touch Up blur currently uses Core Image Gaussian with radius8, while Composer uses MPSImageGaussianBlur(sigma8); their numerical precision and intermediate texture quantization may differ. Color management and ordering of other effects also require controlled original-versus-reconstruction capture comparisons. Our skin operations use explicit display-RGB conversion for shader equations. We do not claim exact bitwise equivalence or that all meeting-app flicker has been eliminated.

Production code retains no camera imagery or calibration data beyond the active processor. Recalibration is requested by incrementing `CameraSettings.toneSyncCalibrationRevision`. Stop/restart resets calibration. `toneSync`, `toneSyncWarmth`, and all prior settings decode compatibly from older presets.

## Validation

`swift test` passed 25 core and7 bridge tests after this implementation; log `swift-tests.log`. Six new skin tests exercise actual Core Image renders, not only helper arithmetic. Tests cover curve endpoints/monotonicity, YIQ coefficients, shader guide/detail equations, skin selection, calibration, tone transform, person/background isolation, zero amount, alpha, and saved settings migration. Synthetic tests do not establish real-face perceptual parity or sustained meeting-client reliability.
