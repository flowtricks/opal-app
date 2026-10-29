# Recovered custom looks G1 / D1 / Q1 / X1 / S1

Analysis date: October 29, 2026. These are recovered RGB transfer equations, not invented photographic presets. The replacement evaluates the equations in its own Core Image kernels. No original metallib, executable, image asset or LUT is loaded by the replacement.

## Evidence chain

The installed Composer 2.0 build 24 resources name five custom filters. The arm64 XPC executable contains a five-entry static dictionary beginning at VA `0x1002a5b90`: G1→MTG1Fragment, S1→MTS1Fragment, D1→MTD1Fragment, Q1→MTQ1Fragment and X1→MTX1Fragment. Dictionary entries occupy `0x1002a5bb0` through `0x1002a5c40` in alternating key/value pairs. The target SHA256 is `544b31ac84ac62e3a3572f89c9ff41ad5d851255d954de39f45ddcae1ff79e83`.

REA 6.8.0 / Ghidra 12.1.4 independently observed the dictionary reference at `0x10000ec90` ([custom-map-xrefs.json](custom-map-xrefs.json), evidence `ev_294bf9d0dd348a016d93479074c9c42f1463181643d8d338039291cab39a224f`), the G1 shader name at `0x1002a5bc0` ([custom-shader-strings.json](custom-shader-strings.json), evidence `ev_f20deaa1b478c099411e284445656c92be8de360a206d12924b8c178f81ae483`), and its containing initializer ([custom-filter-dictionary-init.json](custom-filter-dictionary-init.json), evidence `ev_880ee4fca8908ba9e88e150d6833191b5eee0abb5eda940f211d12df51ed9159`). The initializer reconstructs a five-entry static object. Exact dictionary bytes were separately inspected with ordinary local static tools; the REA pseudocode alone does not spell out every key. [rea-evidence-bundle.json](rea-evidence-bundle.json) retains the three records; [close.json](close.json) records clean session closure.

The shipped XPC `default.metallib` SHA256 is `7c784cd33e8dce15ace3b94e1d21aec5ed48404142d14de3ae0ebc76d6f24bfe`. Its ordinary embedded LLVM/AIR modules were decoded statically without executing the shader. Exact offsets, sizes and module hashes are retained in [the AIR manifest](../effects/air/manifest.json).

| Look | AIR module | Recovered operation |
| --- | --- | --- |
| G1 | [module-46829.ll](../effects/air/module-46829.ll) | Independent fifth-order R/G curves; exponential B curve; clamp |
| D1 | [module-114781.ll](../effects/air/module-114781.ll) | Weighted luminance followed by fourth-order monochrome curve |
| Q1 | [module-71773.ll](../effects/air/module-71773.ll) | Nonlinear RGB curves, weighted grayscale mix, weighted luminance, fifth-order monochrome curve |
| X1 | [module-158829.ll](../effects/air/module-158829.ll) | Three independently parameterized nonlinear RGB curves; clamp |
| S1 | [module-88653.ll](../effects/air/module-88653.ll) | Fifth-order R/G and seventh-order B curves; clamp |

[custom-look-constants.json](custom-look-constants.json) retains the LLVM hex literals and their exact decoded float values. The `*-decimal-air.txt` files are readable numeric projections of those analysis modules. They are research evidence, not replacement source.

## Implementation and validation

[CustomLooks.swift](../../Sources/OpalCore/CustomLooks.swift) independently expresses the recovered equations, using Horner evaluation for polynomials. Coefficients operate in 0–255 display RGB. The public rendering path explicitly converts the compositor's linear RGB to display RGB and back. Input is bounded to ordinary 0–1 RGB. Original fragment output alpha is 1; the replacement preserves incoming alpha so the compositor can retain correct ownership of transparency, then separately publishes opaque camera frames.

[reference-curves.py](reference-curves.py) independently calculates double-precision sum-of-powers reference values from the recovered constants. [golden-curves.json](golden-curves.json) contains thirty fixtures (five looks × six colors). The three [CustomLooksTests](../../Tests/OpalCoreTests/CustomLooksTests.swift) pass: all thirty rendered numeric fixtures within 0.002, alpha/finite-output behavior, and an sRGB-managed roundtrip within 0.003. Command: `swift test --filter CustomLooksTests`.

This verifies the recovered transfer equations and replacement execution. It does not establish bitwise shader parity: original fast-math/power evaluation, float precision, intermediate texture quantization and whole-pipeline color management can differ. Horner evaluation and preserved alpha are explicit differences. Controlled same-input original-versus-replacement capture is still needed for whole-image parity. Standard Core Image photo filters remain separate and retain their original names.

## Bundled presets

[bundled-preset-metadata.json](bundled-preset-metadata.json) parses the original `preset.settings` metadata; [bundled-preset-settings.json](../bundled-preset-settings.json) records their image settings. A1 is **Presenter**, A4 is **This is Fine**: both enable stickers and bokeh with stored value 8.48. A3 is **Ice Breaker** and enables stickers only. Default disables stickers and replacement backgrounds. These are largely decoration arrangements, which the user excluded; there are no hidden color/light settings in these bundled data files to imitate with arbitrary replacement presets. Original `.opalPreset` import/export compatibility is a separate unresolved feature.

The stored bokeh value 8.48 and native setter forwarding a float do not establish an f-stop display mapping. No aperture formula is claimed here.

## Native execution update, 2026-10-29

The independent curve reconstruction above has now been replaced in production with the original compiled `MTG1Fragment`, `MTD1Fragment`, `MTQ1Fragment`, `MTX1Fragment`, and `MTS1Fragment` from the bundled Composer shader resource. This supersedes the earlier no-vendor-library and alpha-preservation descriptions. The original opaque alpha, native floating-point operation ordering and BGRA8 output quantization are retained. Independent direct-Metal oracle tests compare every output byte for all five looks, both whole-frame and cropped CI renders: **zero differences**. The older double-precision equation fixtures remain coarse equation smoke tests; they allow input/output8-bit quantization. See [native shader oracle](../native-shader-oracle/README.md) for the exact evidence and scope.
