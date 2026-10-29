# Tone Sync native calibration and partial-mask oracle

2026-10-29. This checks an entire Tone Sync transform, not only CIFaceBalance with a white mask.

The independent reference runs the original compiled `metalpetal::skintoneadjustment::extractSkin` on a synthetic256×192 display-RGB image and Rh gradient mask, crops the face by the recovered7.5% horizontal/15% vertical inset, runs native DeviceRGB/BGRA8 CIKMeans(count1,passes10,nonperceptual), computes the recovered I/Q calibration, runs native DeviceRGB CIFaceBalance, materializes BGRA8, and finally executes original embedded MetalPetal `blendWithMask` (red component, normal mask mode). The production side runs SkinEffects.toneSync through its normal linear outer context and DeviceRGB bridge.

The original extractor takes source texture0/sampler0 and depth mask texture1/sampler1. It rejects mask values below0.5, computes the recovered skin score from RGB clamped0.0001…0.9999, and retains the original source only when score>0.3. On the test corpus its output matches the current CI extractor byte-for-byte. Both KMeans paths returnRGBA[88,88,75,88] and equivalent I/Q within floating-point rounding(~4×10^-17).

## Bug found

The prior CIBlendWithMask path received the one-component Rh mask directly. In this path it returned the unchanged background for the entire gradient, including mask=1. The original MetalPetal blend explicitly reads red and applies the adjusted foreground. Previous tests used a whiteRGBA image and did not cover the actual mask format.

Before the fix:

| Strength | Warmth | Max byte error | Mean byte error |
|---|---|---|---|
|0.5|0.5|55|6.8871|
|1|0|83|9.5960|
|1|1|111|14.7803|

The isolated CI mask blend reproduced the complete error; skin extraction and calibration did not cause it.

## Fix and verification

SkinEffects now materializes CIFaceBalance to BGRA8 in the original DeviceRGB context, then executes original MetalPetal blendWithMask through ComposerNativeMaskBlend. The helper explicitly requests Rh and selects red component0. It retains GPU-only command-buffer execution and supports cropped regions.

`ComposerToneSyncNativeOracleTests` verifies complete native extraction/calibration/FaceBalance/mask-blend against production, at the three strength/warmth pairs above. AllRGBA bytes match exactly for full output and an off-center crop. Ten focused tests pass, including prior SkinEffects tests. Native720p warm GPU path measures1.68–4.21ms in the existing bounded render test. See `pre-fix-results.txt` and `post-fix-results.txt`.

## Calibration lifecycle correction

Original filter function `0x1000493d4` checks enabled at `+0x10` and needsReload at `+0x40`, dispatching calibration to a global userInitiated queue when reload is true. It continues applying existing I/Q while recalibrating, and applies correction only if both stored components are nonzero. Completion `0x100049920` stores needsReload = (I == 0 && Q == 0). There is no 30-frame interval in this inspected path.

Studio now runs KMeans and its one-pixel CPU readback on a dedicated userInitiated worker queue. Initial frames pass through until calibration is ready; previous calibration stays active during a white-balance reload. Empty initial calibration retries on the next eligible frame. A single in-flight slot bounds retained frames and prevents overlapping calibration work. White-balance revisions and reset advance a generation; obsolete completions release the slot but cannot republish obsolete I/Q. This concurrency bound and generation invalidation are deliberate safety additions to the recovered lifecycle.

Eight lifecycle tests cover repeated frames during an active worker, immediate empty-result retry, cached values during reload, obsolete white-balance results, reset invalidation, unavailable replacement, the original zero-component conditions, and actual frame returns while the worker queue is suspended. Eighteen focused tests pass in `build/tonesync-async-tests.log`. The independent original-shader full-pipeline oracle still matches every byte for all three strength/warmth pairs and cropped output. The warm 720p GPU path measures 1.67–2.97 ms in this run, including the test render.
