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
exponents. It is not the selected model on this Apple Silicon machine. No Google
resource has been copied into the reconstruction.

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

`ComposerPersonSegmenter` implements the Apple branch and throws an explicit
unsupported-GPU error for the unreconstructed non-Apple branch. It creates
half-float masks, preserves their linear numeric coverage, resizes without
extra feathering, uses the original first-frame white-mask behavior, and
reports inference failures through `lastInferenceError` while returning white.
It is confined to the processing queue, with `reset()` creating a fresh
sequence handler. No manual temporal state is retained.

Four targeted tests pass (`build/composer-person-segmenter-tests.log`), including
independent Vision-reference inference on a synthetic frame, half-float coverage
preservation, warmup/reset, and explicit rejection of the wrong GPU branch.
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
