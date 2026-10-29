# Partial Composer preset interoperability

October 29, 2026. Actual `.opalPreset` documents are directory packages, not standalone JSON. The replacement now reads and writes their observed package structure, with an explicit partial-transfer label. This does not establish equivalent rendered appearance or successful loading in every Composer release.

## Observed schema

The shipped A1/A4 presets contain `data.opaldata` version1 with `settings.bokeh.enabled`, `settings.bokeh.bokeh:8.48`, and sticker enablement. `preset.settings` versions2/4 contain display name, visibility/removal flags, architecture and optional timestamps. The shipped default `stickers.opalstickers` is `{"version":1,"stickerList":[]}`. App Info.plist declares the package type `com.opalcamera.opb`, conforming to `public.data` and `com.apple.package`, extension `opalPreset`.

The installed app's own preset directory was then read **only for settings JSON**, under `~/Library/Group Containers/97Z3HJWCRT.com.opalcamera.v2.Opal/Presets/`. The user-created Color Edits preset has full lighting, colorState, effects, zoom, faceLock and bokeh dictionaries. No thumbnail, sticker, background, camera image or resource asset was read or copied. Representative numeric/schema fixtures are inline in `ComposerPresetCodecTests.swift`; personal metadata is omitted.

## Transfer mappings

| Original field | Native destination | Evidence/limit |
| --- | --- | --- |
| lighting/colorState/effects/faceLock/bokeh enabled | Corresponding module enablement | Direct Boolean semantics. Bokeh strength is separately unmapped. |
| lighting.whiteBalance.balance4250 | warmth−2250, displayed4250K | Observed UI/schema pairing and native6500K baseline. Original shader response differs. |
| lighting.exposure.exposure−3 | exposure−3 | Observed UI/schema pairing; visual equality not asserted. |
| lighting.tint.tint0 | tint0 | Direct observed neutral control. |
| lighting.saturation.saturation2 | saturation1.2, displayed20% | Observed raw2↔UI20% calibration. Conversion `1 + raw/10` is a display-scale reconstruction, not a recovered whole-pipeline color equation. Never treats raw2 as a200% multiplier. |
| lighting.vibrance.vibrance0.3 | vibrance0.3, displayed30% | Observed UI/schema pairing. |
| lighting highlights/shadows/contrast raw0 | Native neutral1/0/1 | Only neutral, disabled or automatic states transfer. Nonneutral responses are retained and reported as unmapped. |
| lighting control auto:false | Manual control presentation | Independent enabled/auto metadata is retained. Disabled entries apply native neutral. Original automatic algorithm remains distinct. |
| colorState.hue.colorHues | Eight hue degrees, raw×360 | Normalized turns confirmed by recovered selective-color shader. |
| colorState saturation/brightness arrays | Eight direct multipliers | Recovered shader semantics. Exactly eight finite numbers required. |
| zoom raw0 or disabled | Native1× | Neutral mapping only; nonzero scale unverified. |
| touchUp0, disabled effects | Native neutral/off | Nonzero stored-value scaling is not assumed. |

## Explicitly not mapped

Bokeh strength/kernel; nonzero zoom; nonneutral highlight/shadow/contrast response; legacy brightness; white-balance sampled-color serialization; nonzero Touch Up stored scale; Tone Sync adjustment (not assumed to be amount); filter selected identity/custom looks; pixelate scale; unknown modules. Original values remain intact in `StudioPreset.composerArchive`, including through native JSON export/import. Import leaves current native values unchanged for these unsupported fields and reports the limitation. Color/lighting import clears the prior native sampled-white-point correction when replacing numeric white balance, preventing an old sample from silently overriding imported values.

Imported `.opalPreset` settings are overlaid on current settings; absent values do not pretend to reconstruct original defaults. Native resolution and sensor/backend lifecycle remain unchanged. Native presets remain the complete supported round-trip format for this replacement.

## Export behavior

The save panel offers **Opal Studio JSON — all settings** or **Opal Composer — partial transfer**. Composer export writes `data.opaldata`, `preset.settings` and an empty `stickers.opalstickers`. Supported values update their observed fields. Unmapped original JSON survives when exported from an imported preset. New native presets omit unsupported stored scales rather than inventing them. Therefore unmapped original fields may differ from the current replacement look; this is stated in the save panel and completion notice.

Decorations and replacement backgrounds are disabled in Composer export, and their assets are not copied. The native JSON retains the original metadata for analysis/round-trip purposes but does not load assets or execute archived objects.

## Input validation and tests

Parser accepts settings version1 and metadata versions2/4, checks Boolean versus numeric types, requires finite numbers, rejects malformed dictionaries and wrong color-band counts, and limits each settings/metadata document to2MB. Package I/O reads only the two fixed JSON filenames, requires regular files, and rejects a member resolving outside the selected package. It never follows data-provided resource paths. Native JSON import is capped at8MB.

Six focused XCTest cases cover the observed bundled schema, actual numeric control mappings, partial round-trip with unknown nested fields, exclusion of assets, version/type/count rejection, retention of unmapped current values, and avoiding invented scales in a new export. Hue round-trip comparisons use floating-point tolerance. Results: `build/composer-preset-tests.log`.

No original-app import or export action was invoked by this subtask. Actual Composer acceptance of an exported partial package remains unverified; exact-look compatibility is explicitly not claimed.
