# UI consistency and animation pass — October 29, 2026

Compared the installed Opal Composer with Opal Studio at the same 1172×780 logical window size (2344×1560 screenshots). Used live native UI interactions and the existing Reverse Engineer Anything evidence in this research directory. Measurements are observations, not a claim of pixel identity. Replacement backgrounds and decorations are excluded by request.

## Corrections applied

- Main window:52-point toolbar,260-point sidebar, centered16:9 preview, measured panel inset/radius, compact toolbar badges with white labels and hidden menu arrows.
- Sidebar:Camera/Calls tab line, preset area height,24-point add button,60×40 thumbnails, type sizes, Face-lock placement, Bokeh/Zoom/Focus row spacing,40-point section headers,7-point corners and subtle borders.
- Controls:2-point tracks,12-point ring thumbs, yellow automatic state,28×16 switches with black enabled thumbs; temperature/tint and eight-band color gradients. Brightness now ends at100%, matching the observed original UI.
- Bokeh has its own slider, separate from Effects. Aperture label interpolates observed minimum5.7, quarter4.7, midpoint3.7 and maximum1.8. This display mapping does not establish identical blur response.
- Lighting includes a white-balance picker and explicit Manual state/reset for each row. Multiple sections may remain expanded. Effects contains Touch up, Tone sync and Pixelate; extra reconstruction controls live in Settings.
- Calls contains the measured loop card. Hold captures, release finalizes/plays, Stop clears the clip. Recording controls become unavailable during loop use.
- Preview contains only Zebra/Histogram aids. Transport diagnostics and hardware setup were moved into Settings.
- Recording now opens a separate options window. A second live comparison corrected the original-style hidden title bar,104×68 mode tiles with selected yellow outline, labels below the tiles, separate audio/resolution cards, destination row and52-point record button.
- General settings now expose actual menu-bar/background/login-item behavior. Start at login is not enabled automatically. Original automatic consumer-demand/resolution policy remains a separate gap.

## Animation pass

The replacement previously relied on default control animation. Sidebar visibility, section expansion/collapse, tab state, selected color-band size, switch movement, loop press scale and recording-mode selection now have scoped180ms ease-in-out transitions. Reduced Motion removes the authored decorative animation. UI transactions are restricted to control state, not per-frame video delivery.

Native interaction checks verified final states and that controls remained usable after transitions:sidebar hide/show via Command-/, Lighting expand, Tint increment→Manual→reset, picker cancellation, Calls selection, two-second hold→loop playback→stop/clear, recording-window open, Screen/Camera/Both selection and audio toggle. Screenshots establish final geometry; these checks do not measure original animation curves/durations or prove identical intermediate frames. The180ms timing is independently chosen and remains an exact-parity limitation.

## Remaining visible/behavioral differences

- Independent vector/SF icons differ from the original proprietary artwork; original camera-disconnected3D animation is not reproduced.
- Own presets have independent thumbnails/names. Original preset packages can be partially transferred, but are not copied automatically and do not guarantee the same image.
- Physical focus position is deliberately disabled on the stock capture path because there is no verified setter. It is not represented by a working-looking cosmetic slider. The direct C1 RAM runtime still fails to connect on this camera; stock capture recovers.
- Settings contains operational diagnostics and independently implemented controls; it is not an exact replica of all original preference pages.
- Auto lighting, bokeh/segmentation appearance, some effect mappings, automatic resolution, demand-based pause and original screen/camera inset layout remain unproven or incomplete. See FUNCTIONALITY_AUDIT.md and effects/UI_FIDELITY_AUDIT.md.

This pass closes concrete discrepancies but does not certify “looks and works exactly like Composer.”

Final installed UI verification also checked the corrected full-width recording menus, pure RGB color-band palette, compact expanded Color spacing, and preset thumbnail alignment. A disposable preset was created, renamed and deleted; only the original two native presets remained. The test recording destination was reset, test clip removed, background preference restored off, and login registration left unchanged. The app was left running stock1080p with Bokeh and existing adjustments.

## Preset preview correction

The user reported that Default/Warm tiles showed placeholders instead of the main camera image. Built-in presets have no saved thumbnail, and the old UI only read that optional snapshot. Tiles now observe a shared live thumbnail generated from the same final outgoing pixel buffer as the main Metal preview, including loop substitution. One utility-queue conversion at most every200ms scales to160pixels wide; one pending conversion/publication bounds work regardless of preset count. It does not rerun effects per tile or write live thumbnails to disk. Stopping invalidates pending publications and clears the live image; saved snapshots remain the offline fallback. The full16:9 image is fitted into the60×40 tile without cropping.

Native Release build and strict/deep signature verification passed. The installed running app was visually checked:both Default and Warm showed the live room/window image matching the main processed preview. These tiles show the current output, not independently simulated looks for inactive presets. No new performance measurement is claimed from this visual check.


## Screenshot follow-up — October 29, 2026, 15:47

Compared the user’s 15:40:05, 15:40:29 and 15:40:42 side-by-side references. Corrected uniform 20 pt toolbar badges and white labels, sidebar glyph, Calls underline width (33 pt), tab top spacing, section margins, plus/face-lock/lighting/color/effects icons, selective-color gradient stops, Loop card width and vertical position, and infinity glyph scale. These are reconstructed vector drawings, not copied app assets. Resolution, focus mode, blur and color values still reflect actual settings; they were not changed to imitate the reference values.

Selected tab, sidebar visibility and expanded sections now persist across launches. Verified Calls survives restart and Color/Effects remain expanded after returning to Camera. Live preset previews still show the processed main preview. Loop hold/release entered playback; a second click cleared it. The Loop control retains an explicit accessible button and action after replacing its glyph with a vector. Existing reduced-motion-aware animations remain in use. This targeted pass does not establish complete pixel or functional equivalence.

Release Xcode build and strict deep signature verification passed; updated `/Applications/Opal Studio.app` installed and left running with live capture. Existing Swift regression suites passed (49 core + 7 bridge tests). Logs: `build/xcode-autostart-ui.log`, `build/tests-autostart-ui.log`.
