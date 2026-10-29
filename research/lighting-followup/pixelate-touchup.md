# Pixelate and Touch Up native mapping — 2026-10-29

Sources are the saved REA/exported arm64 disassembly of installed Composer,
its video service, and recovered embedded MetalPetal MSL. No hardware accesses
or new runtime hooks were required for this audit.

## Touch Up

Main constructor0x10011ab70 loads doubles atVM0x100663250 (0,0.5) and
VM0x100663260 (0,0.005): minimum0, maximum0.5, reset0, step0.005.
Main0x100106a1c converts the Double directly toFloat at0x100106a40;
enabledfalse selects0, then setHPSFAmountWithNewAmount is invoked at0x100106a7c.
Display at0x100106aac…ad8 computes abs(raw)*2*100. Accordingly the UI0…100%
now maps to raw0…0.5. Nonzero preset touchUp is forwarded directly rather than
being skipped. The native TouchUp renderer is maintained separately.

## Pixelate

The preset section is `effects.pixelate`, but its value key is `pixellate`.
This spelling is confirmed in the installed saved `data.opaldata` schema;
only numeric settings were inspected, not thumbnails or other user assets.

Main constructor0x10011b2c8…2d8 loads VM0x100663270 (−1,4) and
VM0x100663280 (0,1): minimum−1, maximum4, reset0, step1. Raw−1 is disabled;
levels0…4 are active. Main0x10017df00 converts rawDouble toFloat and forwards
to setPixellateAmountWithNewAmount. Native label formatter0x10017e448 computes
UInt16(1995−raw*5). The parent observed the original UI displays Off for−1;
active labels therefore1995,1990,1985,1980,1975.

Video service0x10005c554 chooses [4,8,10,20,40] and scales by frameHeight/360.
At720p the block widths are8,16,20,40,80; at1080p12,24,30,60,120;
at2160p24,48,60,120,240. `ComposerPixelate` executes the exact recovered
`pixellate` MSL body from build/native-metalpetal-shaders.metal aroundline5407.
It samples block centers with a linear clamp sampler, anchors the grid to the
top-left texture origin, and renders BGRA8 before returning to CI's linear
working space. The computation runs on CoreImage's GPU command buffer without
CPU pixel copies or additional command queue waits.

## Compatibility and validation

Optional composerPixelateLevel distinguishes new native levels from older
pixel-width settings. Old saved documents with no field retain their existing
CIPixellate rendering until adjusted; the UI merely projects their width to
the closest native level. Old TouchUp raw values are preserved on local decode;
new UI writes and native imports use0…0.5. Explicit restore imports both exact
native controls. One-time migratingNewlyMappedEffects only fills old neutral
TouchUp0 and pixelate0/no-native-level settings; nonzero existing edits survive.

Focused GPU tests check known sample positions including partial edge blocks,
linear center interpolation, crop-coordinate consistency, and all resolution
scale tables. Codec tests cover active level0, −1off, all levels, direct nonzero
TouchUp, disabled flags, unknown-field retention, legacy decode, and migration.
No live camera or hardware calls were used in these tests.
