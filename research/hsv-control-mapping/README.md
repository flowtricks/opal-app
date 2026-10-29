# Native HSV control mapping correction

The prior renderer executed the original HSV shader but supplied the wrong hue uniforms. Its synthetic tests independently ran that shader with the same assumed uniforms, so they did not test Composer's preset-to-shader transformation.

Main-app function `0x1002a8434` loads saved `colorHues` controls, validates the normalized range −1…1, then multiplies by a sign-dependent per-band range before converting to Float and sending `setHSV…DistortionWithHue:andSaturation:andBrightness:`. The multiplication and signed table selection are at `0x1002a8504…0x1002a8534`. The saturation-change path independently repeats this mapping at `0x100259868…0x100259898`.

The static table is initialized by `0x1001618dc` from `0x10081fcb8`. Each entry has three doubles: center hue, negative range, positive range, all in turns. Exact bytes are decoded in `native-anchor-table.json`; relevant original instructions are in `main-setter-disassembly.txt`.

| Band | Negative span | Positive span |
|---|---:|---:|
| Red | 60° | 30° |
| Orange | 30° | 30° |
| Yellow | 30° | 60° |
| Green | 60° | 60° |
| Aqua | 60° | 60° |
| Blue | 60° | 30° |
| Purple | 30° | 30° |
| Magenta | 30° | 60° |

The user's imported orange value −0.056 therefore means −1.68°, not −20.16°. Studio previously applied 12 times the original orange shift toward red. The schema keeps its existing stored representation (`hueOffset = normalized control × 360`) to preserve saved/imported/exported controls; `SelectiveColor.shaderHue` now performs the actual original sign-dependent mapping. The CPU reference follows the same control semantics. Values outside −1…1 become zero as in the original setter (ordinary settings are sanitized before rendering).

Saturation is passed directly from saved Double to Float at `0x1002597c4…7c8`. Brightness is passed directly at `0x100259db4…dbcc`; neither uses the hue range table.

Tests check all eight bands and both signs, the actual imported −0.056 value and unchanged export, and an independent native Metal oracle using recovered degree spans rather than production mapping. The oracle covers identity, mixed values, all negative endpoints, all positive endpoints, and the user's orange value, with full and off-center cropped output.

Validation: `swift build --target OpalCoreTests` succeeded; all 23 focused tests passed in `build/hsv-native-range-tests.log`. Independent original-shader full/cropped output matches every byte in all five HSV cases. Warm 1080p native HSV median was 0.86 ms in the bounded test render. This establishes the corrected control mapping, not a completed live whole-app comparison.
