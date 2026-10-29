# Lighting fidelity audit — 2026-10-29

REA 6.8.0 / Ghidra 12.1.4 was used against the immutable arm64 slice of the installed Composer XPC service (SHA-256 `544b31ac84ac62e3a3572f89c9ff41ad5d851255d954de39f45ddcae1ff79e83`). Full tool responses and exported evidence are in this folder. AIR shader inputs remain under `research/effects/air`; decimal text files here decode LLVM hexadecimal float literals for review.

## Implemented

`ComposerLighting.swift` replaces Core Image's generic highlight/shadow adjustment with an independent reconstruction of Composer's recovered local shadow/highlight operator. The native wrapper bypasses at both amounts zero, passes highlight/shadow floats unchanged, and renders BGRA8Unorm. `MTIHighlightShadowFilter` uses the original input and a Gaussian-blurred neighborhood as two shader textures. Its default radius is 30 (init disassembly). AIR module-143677 square-roots RGB, computes luminance/chroma in YIQ, weights the highlight/shadow adjustment by local luminance and the square of the amount, compensates chroma, then squares the inverse-transformed result. The reconstruction implements the public normalized [-1,1] range with a single pass; zero amounts bypass without allocating a blur. The existing app highlight setting has neutral 1, so `highlights - 1` preserves that public convention while passing shader neutral 0.

Relevant native evidence:
- `shadow-output.json`: `ev_f5510c39f467210b8a157706d37593ff5fbfc620aa6e527a017b2efa7d40bb55`, procedure 0x10000823c, original-plus-blur textures.
- `shadow-wrapper.json`: `ev_d3242f8ff5b160213a4096e55aeb32db21f7c7fa65a435f7b793bda2b6f9c2d5`, procedure 0x100018948, neutral bypass/unmodified float uniforms/BGRA8 output.
- `set-highlights.json` and `set-shadows.json`: direct storage of service float parameters.
- AIR module-143677 SHA-256 `5014fe8cb5a10e9296a3f3661f44aa60d30f190495d559a2c06f7995e005ff22`.

The CameraSettings temperature clamp also now permits +5500 K relative to 6500 K, matching the UI's 4000–12000 K range. Previously the upper portion silently clamped at 9000 K.

## Validation

Five constant-color golden vectors independently evaluated from the AIR formulas pass rendered GPU comparison at <=0.006 channel error, including positive and negative highlight and shadow amounts. Neutral bypass and full-range warmth sanitation pass. A synthetic 1920x1080 local-lighting render profile measured 1.09 ms median / 3.45 ms p95 over 20 post-warmup frames. This is an isolated filter benchmark, not whole-camera latency.

## Limits and remaining differences

The new operator is evidence-based, but does not establish full Composer lighting equivalence. Core Image Gaussian sampling can differ from Metal Performance Shaders; the display-RGB boundary is inferred from the non-sRGB BGRA texture flow and needs same-frame original/reconstruction capture for exact verification. UI slider-to-service amplitude scaling beyond the normalized public range has not been recovered. Composer's shader loops for absolute amounts greater than 1; these are outside current controls.

The follow-up in `../lighting-followup/README.md` resolves the split: Kelvin uses physical camera white balance; tint uses custom AIR module-93149 with displayed tint multiplied by3/200. The custom tint is now implemented; Kelvin software fallback remains until a successful physical control application. The original custom temperature shader is not used as a guessed Kelvin conversion. MTIColorMatrix exposure/contrast/saturation functions exist in the linked library but have not been proved to implement the corresponding Composer controls; physical camera controls may contribute. Existing generic exposure, contrast, saturation and vibrance processing therefore remains an approximation. Processing order, Auto policies, and the full sensor/ISP state must still be measured. Selective color already matches the recovered eight-anchor shader and was left unchanged.

## Native GPU execution update,2026-10-29

ComposerLighting now executes the original compiled Tint and shadows/highlights fragments, and uses MPSImageGaussianBlur(sigma30, clamp) with BGRA8 neighborhood texture. ComposerVibrance executes the original embedded MetalPetal source. ComposerCLAHE executes the original embedded RGB→R8 lightness, LUT compute and color-lookup stages plus original MPSImageHistogram configuration. Native whole-frame/crop oracles report byte-exact outputs for tested settings, and CLAHE includes even/odd dimensions. Details and provenance: [native shader oracle](../native-shader-oracle/README.md). These replace reconstructed CI formulas and CI Gaussian implementations described earlier.
