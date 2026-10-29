# Physical lighting and tint follow-up — 2026-10-29

Bounded static investigation used REA/Ghidra on the native XPC service, plus annotated arm64 disassembly of the main app and UVC service. Original app arm64 slice SHA-256: `02bdd24ee2c8ab664703de066d4c0b17860cf7a7ef9ca1100edf17c115482363`. No target code was injected or changed. No camera was opened by this research.

## Proven main-app mappings

- **Temperature is physical white balance.** Main `0x1000fc724…734` truncates the stored Kelvin double to Int32 and calls `setWhiteBalance:`. Auto uses `setWhiteBalanceAuto`. UVC service `0x10001e8cc` first sends white-balance-auto false, then the Kelvin integer unchanged; `UVCCameraDevice` `0x100006dcc` clamps Kelvin to the device-reported min/max. No main arm64 callsite to the XPC's custom global-temperature shader setter was found. Do not map Kelvin onto the custom temperature uniform.
- **Tint:** main `0x100273714`, specifically `0x1002737f8…838`, converts input to shader hue by `input * 3 / 200`. The display scales the shader amount back by `66.66666666666667` (double constant at `0x100675de8`), confirming displayed input units. Native wrapper at `0x100042a94` forwards this hue unchanged to the custom white-balance shader. This provides an exact nonzero tint mapping.
- **Saturation:** main `0x1000fcac4…b20` truncates the stored double to Int32. `UVCCameraDevice.setSaturation` `0x100006fb8` maps raw UI range −10…10 to device min…max using the integer mapping below. Existing Opal Studio saturation1.2 represents original raw2 / displayed20%, so a future hardware application uses `(saturation - 1) * 10` in those raw units.
- **Contrast:** `UVCCameraDevice.setContrast` `0x1000070a8` maps UI raw0…100 to device min…max. Current Opal Studio generic software range and its negative displayed values are not equivalent. Exact main UI initialization and auto policy remain unresolved; do not silently claim equal neutral behavior.
- **Exposure:** main `0x1000fc9fc…a0c` sends Int32(rawEV) to `setAutoExposureCompensation:`. UVC `0x10001f054` maps negative values to `-value + 9`, leaves nonnegative values unchanged, and passes the UInt16 to `setBacklightCompensation:`. Thus −3→12,0→0,+3→3. This is camera firmware compensation, not multiplying pixels by2^EV.

`UVCCameraDevice.mapValue` at `0x100007444` computes `(deviceMax-deviceMin)*(input-uiMin)/(uiMax-uiMin) + deviceMin` using integer multiplication and signed integer division truncating toward zero. Queries supply actual device min/max. No arbitrary nominal range is needed.

## Implemented software correction

Replaced only generic software tint with independent reconstruction of AIR module-93149. The shader's column-vector YIQ-like matrix is intentionally not substituted with a textbook YIQ transform: its recovered constants differ. It adds `shaderHue*0.05226` to the third component, clamps that component to±0.5226, then uses the recovered inverse matrix. Four golden-color vectors pass rendered comparison at≤0.006 per channel, including positive/negative tint and saturated input colors. Neutral tint remains a bypass to preserve unchanged frames.

Kelvin fallback remains `CITemperatureAndTint` with tint0 until the caller has successfully applied hardware white balance; the parent integration must neutralize software warmth only after a confirmed successful hardware application.

## Recovered order

REA `ordered-filter-list.json` evidence `ev_02463aa7673785ecf22fdd1a5931b7dfa2026b5e23138ef1dc87e41efd20f4b1` exposes the FiltersTabPipeline's array:

1. Touch Up
2. Tone Sync
3. Shadows/Highlights
4. CLAHE
5. Vibrance
6. Pixellate (confirmed by `filter38-constructor.json`)
7. White balance / tint
8. HSV wheel (confirmed by `filter48-constructor.json`)

Opal Studio now places its pixelation before tint and HSV, matching these relative positions. CLAHE and the original vibrance shader remain fidelity gaps; global hardware controls precede software capture effects.

## Color-space boundary

The selective HSV shader itself contains no gamma conversion. Existing Opal Studio conversion from Core Image linear working RGB into encoded sRGB before HSV, then back, is consistent with Composer's non-sRGB BGRA8 render targets and the raw camera-buffer path. MetalPetal documents direct pixel-buffer texture mapping, with transfer decoding only when the texture format explicitly uses an `_sRGB` suffix: https://github.com/MetalPetal/MetalPetal#color-spaces-for-cvpixelbuffer . This supports retaining the current HSV conversions; it is not a complete runtime proof of every upstream texture's format or camera transfer metadata. No gamma change was made.

## Validation

`swift test --filter ComposerLightingTests` passes all four tests, including the new tint goldens. The subsequent full suite passes 53 OpalCore and 10 CameraBridge tests. Full pipeline hardware tests are delegated to the integration owner; this subtask did not write hardware settings. First compile attempt was blocked by concurrent C module wiring; a clean subsequent compile and run passed. Earlier `--skip-build` results contained the prior three tests and are not tint validation.

## Release scope

This release integrates proven physical focus and white balance through the separate stock-UVC controller. Saturation/exposure/contrast hardware evidence is retained for future implementation; their original physical behavior is not claimed as shipped. Software exposure, global saturation/contrast, vibrance and CLAHE remain differences. Do not change user-saved Tone Sync defaults to imitate a separately configured Composer session.

## Main-app decompilation bound

The optional REA/Ghidra main-app pseudocode request reached its configured330-second startup deadline before import completed (`main-tint.json`). No main-app pseudocode was produced or used as evidence. The concrete tint/WB/exposure instructions cited above are from the complete LLVM arm64 disassembly and decoded Mach-O constants, cross-checked against recovered XPC semantics. XPC pipeline decompilation succeeded. Both sessions were exported and closed, without repeating the timed-out main import.

## Imported preset correction — 2026-10-29

Read-only inspection of Studio's selected imported `Opal Color Edits` archive confirmed exposure −3, temperature4250K, saturation2, vibrance0.3, and selective HSV arrays. The old importer copied −3 directly to `CIExposureAdjust` and4250K to a6500→4250 `CITemperatureAndTint` transform. Those substitutions were incorrect: the former multiplies pixels by1/8; the latter warms an already balanced frame. A native Core Image neutral-gray check produced RGB[0.27814,0.20489,0.12314] for that temperature transform, confirming the orange direction. Original Composer sends both values to physical camera controls; there is no verified device-independent software equivalence.

CameraSettings now distinguishes optional `composerExposure` and `composerWhiteBalance` intents (value/automatic/enabled) from independent digital exposure/warmth. Import retains physical values and neutralizes the erroneous digital substitutes. Export preserves the physical values/flags. `migratingPhysicalLighting(settings:archive:)` repairs previously imported settings only when their old digital fields still exactly match the archived incorrect conversion; unrelated edits stay intact. Runtime UI/hardware availability is handled by the app integration, not by synthesizing a look in the renderer. This correction does not establish physical parity on unsupported cameras.

A rendered regression feeds neutral pixels through the full effects processor with imported4250K/−3 physical intent and verifies identical output to neutral settings. Targeted codec tests pass9/9, including mode preservation, archive round trip, migration and old JSON compatibility. No physical camera was opened or written by this work.

Physical exposure protocol evidence: original UVC factory0x10000403c constructs PU selector0x01 with2bytes; UVC service0x10001f118 maps negative signedInt32 n to−n+9, otherwise retains n, then verifies it fitsUInt16 and calls setBacklightCompensation. The setter0x1000073b0 forwards to UVCIntControl current. A safe implementation must require descriptor PUbacklight bit8 and GET_INFO0x86 support, query current/min/max/resolution using0x81/82/83/84 (2bytes), then send SET_CUR0x01 (2bytes) only within verified writable bounds and verify current. Do not assume that firmware compensation units equal photographic stops or that another camera's exposure bias matches them.


## Build14 corrections (supersedes approximation notes above)

The native contrast control is software CLAHE, not the unused UVC contrast method. `slider-mappings.md` records main-app callsites: raw0...2, step0.02, display0...100%; Auto preserves the manual value and bypasses CLAHE. The renderer implements 2×2 lightness histograms,256bins, native clip limit/redistribution/CDFquantization and interpolation on Metal. Manualzero remains an active clip limit. Recovered vibrance replaces CIVibrance, retaining the original skin protection and polynomial coefficients. Both have independent rendered golden tests.

Imported nonzero highlights/shadows now map directly to their recovered shader uniforms (own highlights schema stores native+1). Temperature UI uses native2000...7000K/reset4500/step50; physical writes remain clamped to the C1-reported2810...6500K range. Camera saturation is separate from digital saturation: the imported raw2 becomes firmware register60 on this C1's0...100 range. A bounded production-API test on2026-10-29 verified SET2→readback60, then restored the exact prior register50. No reset or firmware command was used.

Build14 integrated tests:86Core+10Bridge pass. These establish individual equations, mode preservation, mask precision and lifecycle guards; they do not establish full original image equality or USBreconnect reliability. Live comparison remains required before that claim.
