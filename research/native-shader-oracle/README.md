# Native Composer GPU oracle and production paths

2026-10-29. The reference is the installed Composer 2.0 build24 XPC resource:

`/Applications/Opal Composer.app/Contents/XPCServices/OpalCameraVideoService.xpc/Contents/Resources/default.metallib`

SHA256: `7c784cd33e8dce15ace3b94e1d21aec5ed48404142d14de3ae0ebc76d6f24bfe`.

The byte-identical resource is bundled at `Sources/OpalCore/Resources/ComposerShaders.metallib` as a SwiftPM resource. The production paths execute its compiled GPU fragments; no vendor app/XPC process is injected or launched. `ComposerNativeShaders` compiles only a matching fullscreen vertex and supplies the recovered argument ABI. Production uses Core Image's supplied Metal command buffer, without a CPU readback, command-buffer commit, or completion wait per frame.

## Independent reference execution

`Tests/OpalCoreTests/ComposerNativeBokehOracleTests.swift`, `ComposerNativeCustomLooksOracleTests.swift`, and `ComposerNativeTouchUpOracleTests.swift` independently create a vertex, render pipeline, sampler, textures, command queue, and pass sequence from the original library. They do not use the production renderer's pipeline or encoding functions. Production runs through CIImageProcessorKernel, including input quantization, linear/display conversion, regional texture addressing, and final color-space conversion.

The fixed128×96 synthetic image has RGB bytes `(11x+3y)%256`, `(2x+7y)%256`, `(5x+13y)%256`. Its mask is1 before x40, linearly falls to0 by x70, and stays0 thereafter. Tests compare every RGBA byte for the complete frame and crop(x37,y11,w47,h29). CI crop coordinates use bottom-left origin; direct Metal reference texture rows use top-left origin.

Results:

- Native four-pass bokeh(radius11): **0 differing bytes**. Pre/Alpha1/Alpha2 areRGBA16Float; finalBGRA8. Pre power is half(sqrt10), final reciprocal is float(1/sqrt10). Blur directions120°,240°,360° scale by width/height.
- G1,D1,Q1,X1,S1: **0 differing bytes**, each complete and cropped frame. Production now uses the native fragments and their opaque alpha/BGRA8 quantization rather than independently rearranged polynomial math.
- TouchUp amounts0.25,0.75,1: **0 differing bytes**, each complete and cropped frame. Native guide→MPSImageGaussianBlur(sigma8,edgeClamp)→native composite, BGRA8 intermediates. LUT bytes retain the recovered natural cubic spline(0,0),(120,146),(255,255), integer truncation. Oracle independently evaluates that spline.

Focused14-test log: `build/native-oracles-xctest.log`. Target-only build avoids concurrent app-UI work:

```
swift build --target OpalCoreTests
xcrun xctest -XCTest 'OpalCoreTests.ComposerNativeBokehOracleTests,OpalCoreTests.ComposerNativeCustomLooksOracleTests,OpalCoreTests.ComposerNativeTouchUpOracleTests,OpalCoreTests.CustomLooksTests,OpalCoreTests.SkinEffectsTests' .build/out/Products/Debug/OpalCoreTests.xctest
```

The standalone earlier harness `main.swift` additionally compared the prior reconstructed HSV and bokeh implementations with the original native library. HSV identity was byte-exact; imported selective-HSV settings differed by1 in only1 of36,864RGB channels(mean0.000027/255). Prior CI bokeh differed by up to11/255(mean0.1664/255,p99=3), chiefly at mask transitions. Replacing bokeh with the original compiled fragments removed all of those differences on the identical input.

## Limits

These are same-input shader checks, not a claim that every full-app frame or camera control matches. Segmentation, capture input, filter ordering, hardware settings, DeviceRGB boundaries, and other effect stages need separate evidence. At this revision CLAHE, vibrance and lighting/tint still include reconstructed math; their own native comparisons must not be inferred from these results. The tests use the current Apple GPU and macOS. No physical camera or call client is touched by this harness.

## Additional native stages

The full MetalPetal shader source embedded in Composer's XPC is now copied verbatim to `ComposerMetalPetal.metal.txt` (SHA256 `a02868198232539b7a44ac10797b16b49e3fe1477b194d058b20a26ff94dd5b9`). It compiles once per device with `TARGET_OS_SIMULATOR=0`, as required by its source. This is runtime compilation of original source, not rewritten shader equations. The shared helper uses the compiled metallib first and the original embedded source for native MetalPetal functions absent from that metallib.

- Native shadows/highlights: MPSImageGaussianBlur sigma30, edgeClamp, BGRA8 intermediate, original compiled `shadowHighlightAdjust`. Native Tint: original compiled `whiteBalance`, temperature0, displayed tint×3/200 hue. Native Vibrance: original embedded `vibranceAdjust`, skin protection true, original coefficient vector and gray transform. Nine nonneutral setting cases, complete and cropped renders: **zero differing bytes**. Native1080p lighting median1.18ms/p95 3.36ms in the existing bounded profile test.
- CLAHE: original embedded RGB→lightness fragment toR8, four MPS histograms, original LUT compute toR8, original lookup fragment toBGRA8. Native disassembly at0x100098600 initializes256 bins, no alpha, min0/max1, zeroHistogram=false. Resolve0x100097cf4 uses tile clip rectangles and histogram byte strides; LUT uses256 bins,4 tiles, truncated float clip limit at least1. Output0x100098b4c pads dimensions to even and uses mirrorRepeat sampling(mode3), scale=padded/original. Regression oracle tests3 clip limits(0,0.3,2), even128×96 and odd127×95 images, whole and cropped renders: **zero differing bytes**. Native720p CLAHE median1.73ms/max3.42ms.
- HSV selective colors now execute the original compiled fragment with eight float3 buffers, including the native output quantization. Identity and a nonneutral eight-band setting also match the direct native oracle byte-for-byte.

Additional logs: `build/native-lighting-oracle-tests.log`, `build/native-clahe-oracle-tests.log`, `build/native-hsv-tests.log`. These updates supersede the earlier CLAHE/vibrance/lighting/tint reconstruction limitation; whole-app boundaries and camera state still require separate validation.

## Tone Sync whole-effect oracle

A later full Tone Sync oracle found that the CI mask blend was treating the actual Rh mask as empty, despite earlier whiteRGBA-mask tests passing. The fix materializes original DeviceRGB FaceBalance output toBGRA8 and uses original MetalPetal red-channel blendWithMask. Native extraction→native DeviceRGB KMeans→FaceBalance→Rh blend now matches production byte-for-byte for3 strength/warmth settings, whole and cropped outputs. Earlier errors reached111/255. See [Tone Sync oracle](../tonesync-oracle/README.md) for before/after evidence and the remaining unsuccessful-calibration retry timing distinction.
