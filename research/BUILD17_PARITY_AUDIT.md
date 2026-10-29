# Build 17: native control mapping and mask boundary corrections

The user's live build16 comparison disproved whole-pipeline equivalence despite passing individual shader comparisons. Studio appeared too red, softer, and had a more noticeable shoulder outline. Both applications were showing 720p; Composer used manual focus0.5m while Studio used autofocus, so sharpness comparisons also require matched focus.

## Proven hue error

Composer's saved colorHues values are normalized controls, not shader hue turns. Main native function0x1002a8434 multiplies each value by a color-band-specific, sign-dependent anchor distance before sending the XPC shader uniform. An independent saturation setter repeats this transformation. The eight pairs are retained in research/hsv-control-mapping/README.md.

For the user's preset, orange−0.056 maps to −0.0046667 shader turns (−1.68 degrees). Studio sent−0.056 turns (−20.16 degrees), exaggerating this adjustment12× toward red. SelectiveColor now performs the recovered mapping. Existing saved/imported values remain unchanged. The UI now exposes normalized−100…100% and sanitization preserves the full native range instead of clipping it to the old incorrect bounds.

Native shader comparison fixtures now independently apply the main application's recovered control mapping, rather than simply sending the same already-mapped test uniforms to both paths. They cover both signs, all bands, and the actual imported orange value. The prior tests proved shader execution only and missed this controller-to-shader error.

## Proven final-mask boundary

The Apple segmenter initially returns an R16-half mask, but the subsequent native SegmenterFilter Apple branch always resizes/quantizes it to R8Unorm before Bokeh, ToneSync and TouchUp. Build16 passed the half-float mask directly. The final R8 boundary and downstream input formats are corrected using the actual native passthrough shader. This is an established code difference; its contribution to the visible outline must still be evaluated live.

## Verification and remaining work

Focused hue checks passed23 tests before the final integrated run. Additional import/export coverage preserves all normalized hue endpoints. Final integrated/build results and live observations will be appended after completion. No new whole-app equality claim follows from these isolated comparisons. Notarization remains pending; the user explicitly requested local testing before notarization.

## Local installation checkpoint

All126 OpalCore and10 CameraBridge tests passed (`build/build17-integrated-tests.log`). The universal archive and Developer ID export succeeded. Build17 was installed at `/Applications/Opal Studio.app`, with the previous app preserved in a timestamped build backup. It is signed but not notarized. The C1 preview started and the user began testing the sliders. Live matched-settings acceptance is still pending; user changes to zoom, bokeh and focus were observed, so no equality claim is made from those changing frames.

Read-only hardware snapshot after quitting Composer: lens142/manual, WB4250/manual, exposure register12 (Composer−3), saturation register60 (Composer2). The diagnostic now reports these fields without writing controls. Plug-in launching still needs to be restored when the user releases the controls.

## User acceptance and startup

After testing the installed build17, the user reported “it looks great now” and requested a GitHub release and reusable DMG. This is live visual acceptance of the tested build, not a measurement of every camera/client combination. Camera plug-in launch was restored through General settings; launchctl confirmed a running helper with parent bundle version17. Login launch remained enabled. Current user-adjusted settings were preserved.
