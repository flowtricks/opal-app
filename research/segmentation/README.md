# Composer person-mask parity (2026-10-29)

Scope: static analysis of the installed OpalCameraVideoService arm64 executable,
using the retained REA investigation and annotated disassembly in
`.analysis-tools/xpc-annotated-disassembly.txt`. Selected instructions are retained
in `native-apple-branch.txt`. No vendor executable or camera was launched for this
follow-up. Swift synthetic inference tests invoke Apple's Vision framework only.

## Proven default selection

Frame pipeline 0x100032300 reads global0x1002bd9b9. Its initializer0x10000eba8
checks whether `MTLCreateSystemDefaultDevice().name` contains `Apple`.
An Apple GPU calls SegmentationService at0x10002924c (call0x100032338).
A non-Apple GPU calls GoogleMeetsService at0x10002b570 (call0x10003255c).
This is a hardware branch, **not a failed-Apple-inference fallback**.

GoogleMeets.mlmodelc is bundled in the video-service resources: RGB256×144 input,
two logits per pixel, softmax exponent of foreground logit divided by both
exponents. It is not the selected model on this Apple Silicon machine. The later non-Apple follow-up below bundles this resource.

## Apple branch

- A persistent VNSequenceRequestHandler is initialized at0x1000290dc…f4.
- The initial invocation increments skippedFrames from0 to1 and returns nil
  (0x1000292a0 and0x100029614). Subsequent invocations infer; there is no repeating
  frame-skip in this method.
- The renderer returns CIImage directly from the incoming MTIImage, without an
  explicit downscale in0x10002b098…10002b104.
- Each inference creates a **new** VNGeneratePersonSegmentationRequest
  (0x100029668…690). Quality is1 (balanced); its generic Intel-GPU alternative
  is2 (fast), but Intel does not take this default branch.
- Output format is0x4c303068, `kCVPixelFormatType_OneComponent16Half`.
- Persistent handler performs onCIImage with orientation1 (.up) at0x10002977c.
- Result uses a clamp-to-zero sampler (Metal address mode4), then resizes to
  input CIImage extent width/height with output pixel format25 (R16Float), at
  0x1000298b4…930. Resize helper0x10008869c mode0 stretches to the exact size.
- The Apple path bypasses SegmenterFilter surface blur. Global0x1002bd978 is
  initialized as NOT Apple-GPU flag via0x10000e9e0…ea74. The two-stage256×144
  surface blur at0x10000daec therefore applies only to the non-Apple branch.
- No additional Gaussian1.2 or explicit temporal35% mask dissolve appears in
  this Apple call path. Those were reconstruction inventions.
- Nil/failed masks produce MTIImage.whiteImage in caller0x10003256c…598. There is
  no switch to Google or reuse of an old unrelated mask. This preserves the
  sharp foreground frame while segmentation is unavailable.

## Implementation and verification

`ComposerPersonSegmenter` implements the Apple branch and now selects the recovered GoogleMeets branch on non-Apple GPUs. It creates
half-float masks, preserves their linear numeric coverage, resizes without
extra feathering, uses the original first-frame white-mask behavior, and
reports inference failures through `lastInferenceError` while returning white.
It is confined to the processing queue, with `reset()` creating a fresh
sequence handler. No manual temporal state is retained.

Four targeted tests pass (`build/composer-person-segmenter-tests.log`), including
independent Vision-reference inference on a synthetic frame, half-float coverage
preservation, warmup/reset, and the later native Google branch inference.
This does not establish visual parity for a live person or native Metal-vs-CI
resize at subpixel boundaries. Parent owns live comparison and integration.

## Capture format and bokeh radius boundary

Original UVC service0x100019078 validates requested resolution, falling back to
1920×1080 when unsupported. It calls0x10001b384 before creating the new capture
session. That helper keeps exact width/height matches in device.formats order
and sets the first one (setActiveFormat at0x10001b820), with no subtype/FOV/FPS
ranking. New-session setup starts at0x10001bc68, after that selection.

The native bokeh wrapper sends raw radius multiplied by startup strength
(default1); MTIBokehFilter normalizes directional radius by its input image
width/height, producing a radius measured in input pixels. No resolution factor
is present in the wrapper or four blur passes. This supports raw11 as11 input
pixels; the exact upstream working-image versus final-output relationship
remains to be traced for zoom and non-native resolution cases. Do not invent a
720p-relative multiplier from the aperture label.

## Non-Apple implementation follow-up

`ComposerGooglePersonSegmenter` now bundles the exact shipped GoogleMeets model
and invokes its original compiled Metal softmax and surface-blur fragments.
Native model setup0x02be3c uses `.all` compute and `.centerCrop`; each inference
uploads interleaved two-channel Float32 output to RG32Float. Contrary to the
wrapper's requested R16Unorm format, the Softmax output implementation0x007f3c hardcodes
R8Unorm at0x008010. Its subsequent full-source resize is R16Unorm (SDK raw value20).

SegmenterFilter0x00daec genuinely crops the full-size mask at top-left pixel
rectangles(0,0,256,144) and(0,144,256,144), then performs radius8 grayscale surface
blur, threshold100; it then uses sourceRGB resized256×144 as the guide for a
second surface blur at threshold75. Both results and the final resize are R8.
These unexpected crops are retained literally rather than silently corrected.
Constructor0x00e1b4 and MTISurfaceBlurFilter0x007298 establish radius, thresholds,
symmetric Gaussian weights (15 taps in16 floats, sigma8), and bsigma=2*threshold/255.
AIR modules76397/82605 confirm only weights0...14 are accessed. The original
fragments are specialized with the exact radius function constant.

A synthetic720p black-frame test performs actual bundled-model inference and
native GPU refinement successfully (no error, non-white finite mask). All four
person-mask tests pass in `build/composer-google-tests.log`. This is an offline
Apple-Silicon execution of the non-Apple algorithm, not verification on an
Intel/AMD Mac or a live person. Native Intel driver/CoreML compatibility,
orientation and the surprising crop behavior still require target-host visual
verification. Failures return native white-mask behavior with an exposed error;
there is no fallback to a different segmentation model.

The Google refinement is encoded by a CIImageProcessorKernel using the outer
Core Image Metal command buffer. There is no separate GPU queue or CPU wait.
Its small network logits are retained as owned Data until lazy rendering; all
intermediate texture passes stay on GPU. Apple mask resizing now uses the
original Metal passthrough function, linear clamp-to-zero sampler and R16Half
output, replacing CI affine reconstruction. An independent CPU bilinear/zero
border/half-float oracle passes to within0.00002. All four mask tests pass.

## FXAA startup default

Main `StoredIMXModuleProperties` constructor0x047d38 initializes the first two
CameraModuleCapabilities bytes to0,1 at0x047dd8...ddc. Swift reflection descriptor
0x6ba1ac/fielddescriptor0x721db0 identifies byte0 as`fxaaEnable`.
Main0x29e660 compares that byte with1;0x29e794 stores the boolean into the video
initialization object atoffset0x14. XPC0x0449ec forwards it as the constructor
stack byte, and0x01942c assigns the CameraModulePipeline FXAA enabled flag.
Thus the default is **off**. Device-reported module capabilities may override
that value; this audit has not read the live hardware capability response and
does not justify globally enabling FXAA on all cameras.
