# Native lighting UI bounds and Auto actions

Read-only analysis of the saved arm64 Composer disassembly and matching shipped binary. No runtime camera interaction. Addresses are VM addresses in `OpalComposer-arm64`.

- **Temperature:** constructor `0x1001a17e0` through `0x1001a1c60` loads `0x100669cd0` ([2000,7000]) and `0x100669ce0` ([4500,50]) at `0x1001a1c14` through `0x1001a1c24`: UI range2000...7000 K, reset4500 K, step50 K. This UI range is separate from the C1 hardware descriptor range2810...6500 K.
- **Contrast:** slider constructor `0x1001a36cc` through `0x1001a3af8`; at `0x1001a3a9c` loads constants at `0x100669d00` (Double pair 0, 2), then `0x100669d30` (Double pair 0, .02). Shared slider fields receive range 0...2, reset 0, step .02. Label is abs(raw) * .5 * 100 (`0x1000941ec` onwards). Service receives raw Float unchanged.
- **Contrast Auto:** closure `0x1001a586c` via `0x1001a6e14` handles selection enum 4. Selection (1,0) enters `0x1001a5920`: sets autoValue to Optional.some(0), sets isContrastOn false, calls `0x100093944` to disable CLAHE. Selection (0,0) enters `0x1001a58a0`: autoValue nil, isContrastOn true. Manual contrast is preserved across this action. Auto bypasses the filter; it does not run CLAHE with a special automatic clip limit. Imported enabled=true/raw0 is a different state: enabled raw0 still runs CLAHE with histogram clip threshold1.
- **Highlights:** constructor `0x1001a29e4` through `0x1001a2dd8` uses constants `0x10065d0b0` (-1,1) and `0x100669d30` (0,.02). Range -1...1, reset0, step.02. Label raw*100 at `0x10004ef48` through `0x10004ef50`. Main calls setHighlightsAmount with Float(raw) directly at `0x10004d1bc` through `0x10004d1cc`; alternate model does the same at `0x10018c3d4` through `0x10018c3ec`.
- **Shadows:** constructor `0x1001a2e28` through `0x1001a321c` uses the same two constant pairs: range -1...1, reset0, step.02. Label raw*100 at `0x10018d610` onwards. Service gets Float(raw) directly at `0x10018c63c` through `0x10018c648` and `0x10004d76c` through `0x10004d788`.

Opal Studio historically stores highlights neutral as1. Its importer should therefore translate native raw to raw+1, and its renderer must subtract1 before invoking ComposerLighting. Shadows already share native neutral0. This is schema translation, not native shader scaling.

# Capture format ordering correction

Native UVC setup `0x100019078` checks supported dimensions and falls back to1080p if absent. It calls format helper `0x10001b384` at `0x10001915c`, BEFORE session setup `0x10001bc68` at `0x100019284`. The helper picks the first format with exact width and height and writes activeFormat at `0x10001b820`; it does not rank pixel subtype, field of view, or frame rates. New session allocation occurs `0x10001bd9c` through `0x10001bdc8`; session preset follows through helper `0x10001b97c`.

CameraEngine now mirrors explicit first exact-format selection before fresh session creation and leaves activeVideoMin/MaxFrameDuration untouched. It uses first1080p as sensor fallback for unavailable dimensions, while retaining its explicit refusal to upscale unsupported higher output requests. Earlier comments claiming Composer only selects a preset were incomplete: the UVC helper performs the preceding activeFormat write.

# Final zoom and bokeh bounds

Zoom constructor0x10024d1e0…1f0 loads VM0x100673f70=(0,0.375) and
VM0x100673f80=(0,0.00375): raw0…0.375, reset0, step0.00375.
Main0x1000199dc converts rawDouble→Float unchanged before setZoomAmount.
Mainlabel0x100019a1c…44 computes abs(raw)/0.375*1.5+1 =1+4raw.
XPCsetter0x10001e718…738 converts that Float→Double and stores
ZoomFilter.adjustedPadding at+0x18 without scaling. ZoomFilter0x1000102f8…310
computes physical crop factor1+1.5raw and divides width/height by it.
Consequently native displayed2.5x corresponds to physical1.5625x: the display
and crop scales deliberately differ. CameraSettings.zoom remains the physical
factor; zoomDisplay now exposes native labels. The UI writes physical1…1.5625
in steps0.005625. Older saved out-of-range crop factors are retained until edited.
The codec physicalfactor mapping remains1+1.5raw; earlier assumption that raw
UI allowed0…1 was corrected, not the proven rendering equation.

Bokeh constructor0x10024ccf4…cd08 loads VM0x100673f50=(0,11) and
VM0x100673f60=(0,0.11): raw0…11, reset0, step0.11. BokehChange's initial
PublishedBool istrue at0x1000889ac…9c4. Its initial PublishedDouble is7.6
(bitpattern0x401e666666666666) at0x1000889e8…8a04. The reset path0x10008959c…5e8
and decoder fallback0x100089994…9a0 independently confirm7.6. Fresh Studio
settings now use native7.6; old saved documents lacking composerBokehRadius
continue decodingnil to retain their legacy rendering until explicit migration.
