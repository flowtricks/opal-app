# Native filter identity and lighting modes — 2026-10-29

## Filters

The saved REA-derived main arm64 disassembly provides a complete Codable path:
FiltersChange decoder at0x100137b78 obtains its keyed container. Key0 decodes
Bool at0x100137bf4 (enabled); key1 decodes optionalDouble at0x100137d50
(intensity); key2 decodes optionalString at0x100137e98 (selected). The selected
String goes directly to0x100138770, then0x10013935c, where it bridges toNSString
and invokes setFilterNameToApplyWithNewFilter at0x1001393d4. It is not a nested
object or an index. Key names also appear in observed data.opaldata schema.

Intensity is converted directly Double→Float at0x100139220; default selection
chooses0.5 at0x100139228, and the Float is sent unchanged at0x100139258.
Video service0x10001e808…818 stores that Float directly atVideoService+0x38.
This establishes parameter mapping, not the exact partial-intensity blend
color space. The existing CIDissolveTransition still warrants native-stage
comparison before claiming pixel identity at fractional intensities.

Names in the shipped resource JSON define filter identities:

| Resource | Native name | CoreImage operation |
|---|---|---|
| chrome_pipeline.json | C1 | CIPhotoEffectChrome |
| fade_pipeline.json | F1 | CIPhotoEffectFade |
| instant_pipeline.json | I2 | CIPhotoEffectInstant |
| mono_pipeline.json | M1 | CIPhotoEffectMono |
| noir_pipeline.json | N2 | CIPhotoEffectNoir |
| process_pipeline.json | P1 | CIPhotoEffectProcess |
| tonal_pipeline.json | T1 | CIPhotoEffectTonal |
| transfer_pipeline.json | T2 | CIPhotoEffectTransfer |

Custom names G1,D1,Q1,X1,S1 come from their corresponding resource JSON. Their
native GPU implementations are maintained separately. Opal Studio now uses
these names in filter labels, imports/exports selected Strings, preserves
selection when disabled, transfers intensity directly, and retains unknown
identities without applying an invented substitute. New default intensity is
0.5; old saved documents with no intensity still decode as1.0 for compatibility.

## Lighting mode preservation

The original automatic-mode closures manipulate separate autoValue/enabled
properties, without resetting the stored manual value. Contrast's exact path
is documented in slider-mappings.md. Highlights closure0x1001a5d58 likewise
sets autoValue Optional.some(0) and enabledfalse in its Auto branch at0x1a5e0c;
Manual usesOptional.none and enabledtrue. It calls enable/disable helper
0x10004c5d0 at0x1a5ea4. Vibrance enable helper0x10022cf34 sends the enabled
Boolean to toggleVibranceEnabled at0x22cfbc, then only whenenabledreads and
reapplies the saved raw value at0x22d054…068. Shadows uses the corresponding
closure/helper0x1a6438→0x18c274.

Studio retains native manual values/auto/enabled for tint, vibrance, highlights,
and shadows in composerDigitalLighting. Existing effective software values
remain neutral during Auto, so no new render stage is introduced. Preset
round-trip retains disabled values rather than replacing them with zero.
Lighting rows provide Auto/Manual choices; Manual restores the retained value.
Physical temperature/exposure/saturation Auto likewise preserves requested
manual value; hardware behavior remains the existing controller responsibility.

Validation:16 focused ComposerPresetCodecTests pass, including all13 filter
identities, disabled selection, partial intensity, unknown preservation,
malformed selected-object rejection, and automatic lighting value/flag
round-trips. The app target compiled during the focused test command.

## Bounded intensity-consumer follow-up

A scan of the complete saved annotated XPC disassembly found exactly two
scalar Float accesses at object+0x38: setterstore0x10001e818 and constructorstore
0x100044a50. No scalar Float load or address-of for this field was found. This
is evidence of no located consumer, not a proof that indirect copies cannot
consume the field. No native partial-intensity blend function was recovered,
so no replacement blend helper was invented.

The VideoService.areFiltersOn dynamic offset0x1002bdac8 is read at0x10002da00.
That enabled branch loads the pipeline array atglobal0x1002bda38 and iterates
its entries at0x10002da50…da9c, calling0x10003dc10 for each. This generates the
filter preview collection; it does not read selectedname or filterIntensity.
The field setter alone must not be described as proof of final-output blending.
A live original selection/intensity comparison remains the useful discriminator.

Native UI evidence from the parent additionally established that Manual labels
depend on !automatic even when enabledfalse. Lighting row presentation now uses
that condition; render enablement remains independent. Imported disabled/manual
Tint0 andContrast0 therefore retain visible0/Manual rather than appearingAuto.

## Final bounded graph follow-up before build16

The areFiltersOn branch's per-entrycallee0x10003dc10 is a registered-window
postprocessing dispatcher. It resolves a String windowID in a dictionary at
0x10003ddf4…de00, with failure diagnostic at0x10003df08: "No post processing
filter found for window ID". It reads that window's frame-rate data and
computes1000/fps at0x10003dfdc…dfe0. It builds an asynchronous per-window
closure at0x10003e138…190 and schedules it at0x10003e270. The caller at
0x10002da50…da9c loops every registered entry; it supplies windowID and
current texture, not VideoService.filterIntensity or filterNameToApply.
This is a collection of effect-preview render windows, not a demonstrated
selected-filter blend in the final camera output.

The main app's selectedFilter getter0x100138684 has no direct branch-and-link
callers in the recovered executable. References to its keypath0x100664740
are confined to FiltersChange encode/get/set paths. The intensity keypath
0x1006646f8 likewise appears only in that model's decode/encode/get/set paths.
Indirect SwiftUI/keypath dispatch cannot be excluded solely from absence of
BL references. No graph consumer of selected-filter/intensity was recovered.

The strongest supported conclusion is that these fields are stored and
serialized, while the recovered active custom/photo-filter graph is the
per-window preview path. Whether an indirect UI composition path uses the
selection remains unverified. To resolve it, the original app must be observed
while selecting a filter and changing intensity, comparing both its main
preview and virtual-camera receiver. At this checkpoint the parent reported
the Mac locked, preventing that runtime discriminator. No inference of an
encoded-space or linear-space blend is justified by these setter paths.

No EffectsProcessor change or invented native blend helper was made. Studio's
fractional CIDissolveTransition remains an acknowledged behavior gap rather
than being claimed as recovered Composer behavior. Shader execution tests for
full-strength custom looks establish shader identity, not this missing
selection/intensity integration path.
