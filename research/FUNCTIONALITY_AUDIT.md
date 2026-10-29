# Composer functionality and interaction audit

October 29, 2026. This audit separates an absent implementation from an implementation whose behavior has not been compared. The replacement is not yet an exact functional or visual copy. Decorations/stickers and replacement backgrounds remain excluded by the user's scope. Performance and immutable complete-frame output remain requirements while closing interaction gaps.

## Evidence and scope

- `rea-interface-builder.json`: decoded shipped `Contents/Resources/Base.lproj/Main.storyboardc/MainMenu.nib`. Menu declarations and shortcuts are direct static evidence, not proof every item appears in the running app.
- `menu-shortcuts.json`: readable projection of those exact archived titles, key equivalents and modifier masks. No new decompilation or target execution was needed for this projection.
- `ui-feature-labels.json`: original localized control, loop, settings and recording instructions.
- `bundled-preset-settings.json`: four original preset settings excerpts; these do not establish complete preset compatibility.
- `effects/README.md`: recovered Touch Up/Tone Sync math and explicit remaining differences.
- `OpalStudioApp.swift`, `StudioModel.swift`, `LoopController.swift`, `CameraSettings.swift`, `EffectsProcessor.swift`: replacement behavior audited from source. Source behavior is distinguished from observed UI behavior below.
- Root agent's live original-app comparison this turn: right pane approximately 260 px, 52 px header, 116 px preset area, yellow enabled card title, black thumb/yellow track; expandable Lighting values show Manual buttons. Clicking Tint Manual removed its displayed value/Manual button, changed the slider thumb yellow, and clicking the slider restored the manual presentation. Automatic image-processing policy is not established by that visual observation.

## Ranked gaps

| Priority | Area | Finding | Classification / next check |
| --- | --- | --- | --- |
| 1 | Lighting automatic/manual state | Existing settings store only numeric values, so reset-to-automatic visual state and independent per-slider manual overrides were absent at audit start. Original live Tint observation confirms a two-state interaction. | Missing state/interaction; automatic algorithm and defaults remain unverified. A cosmetic Auto state must not falsely claim image-based adaptation. |
| 1 | Bokeh independence | Replacement `needsPersonMask` is gated by `effectsEnabled`; turning off the Effects card also disables separately displayed Bokeh. | Concrete source behavior; original independence must be checked live before changing the core. Reported to root/core owner. |
| 1 | Loop/recording interlocks | Original strings say loops are disabled while recording and stop loop to use recording. UI prevents loop capture while recording, but `StudioModel.toggleRecording()` originally allowed recording to begin during loop playback/capture. | Concrete asymmetry. New Camera menu opens the recording window; `StudioModel.toggleRecording()` now rejects starting while a loop is playing, recording or finalizing. |
| 1 | Loop button semantics | Original labels say hold to record, release to play, press stop to clear. Current hold starts a new recording even if a loop is playing, and Stop calls `stop()` retaining the old clip; separate Clear deletes it. | Different behavior; confirm original stop clearing at runtime, then make the primary loop interaction match. Retaining a hidden clip should not silently change expected primary-action behavior. |
| 1 | Preset file compatibility | Original `.opalPreset` is a package with versioned settings/metadata. A subsequent read-only audit found full saved lighting/color/effects schema. | Partial package import/export implemented with observed mappings, explicit warnings and retained unmapped metadata. Six tests pass. Original-app acceptance and exact appearance remain unverified; see `PRESET_INTEROPERABILITY.md`. |
| 2 | Menu actions and shortcuts | Previously only Start Camera, Stop Camera, Import, Export were registered. Original has File preset management, View aids/sidebar, Camera mute/Face-lock/module actions, and Settings. | Implemented this turn in `StudioCommands.swift`; root integrates its commands and view notifications. Exact observed shortcuts preserved where applicable. |
| 2 | Preset lifecycle | No rename/update/revert/cycling; deleting selected preset left an orphan selected UUID; selection wasn't restored on app restart. | Implemented this turn: model methods, persisted selected ID, orphan cleanup, menu access. Original automatic save/reset semantics remain unverified. |
| 2 | Animation and transitions | At audit start there were no explicit animation/transition modifiers for sidebar, accordion cards, tab movement, badges or hover changes. Standard SwiftUI control animation alone does not reproduce Composer's interaction timing. | Missing authored transitions. Root owns live comparison and UI rewrite. Original durations/easing are unverified; do not invent claims of exact timing. |
| 2 | Face-lock sensitivity | Original settings expose Slow/Default/Fast; replacement hardcodes face detection every five frames and 0.8/0.2 center smoothing, with minimum 1.5× crop. | Missing sensitivity control; default dynamics not proven identical. Physical focus/exposure coupling differs by backend. |
| 2 | Resolution and lifecycle | Original exposes Auto/Manual resolution and pause video when not streaming. Replacement has explicit fixed720/1080/4K and manual start/stop. | Missing automatic policy; fixed format stability is useful but not parity. Consumer-aware demand and camera/preview policy need defined behavior before implementation. |
| 2 | White-balance sampling | Original live Lighting shows eyedropper. Replacement only numerical digital warmth/tint plus sensor controls. | Missing eyedropper sampling workflow at audit start. Sensor white balance and digital temperature must remain distinguishable. |
| 2 | Custom filters | Original has G1/D1/Q1/X1/S1 identifiers beyond standard photo effects. Replacement only supplies identified Core Image filters. | Missing reconstructed appearance/mapping. Do not rename unrelated filters to look complete. |
| 1 | Recording modes/workflow | Live original inspection subsequently established a separate Record window with Screen/Camera/Both, microphone, resolution and destination options. Earlier replacement had camera-only direct save. | Implemented in this pass: options window, screen/PIP capture, selected microphone and persistent folder. Synthetic compositor and actual file encode/decode pass. Original Both layout and real screen/microphone runtime acceptance remain unverified; see `RECORDING_PARITY.md`. |
| 3 | Firmware/update/support commands | Original archived menu has firmware update, update check, feedback, logs and uninstall. Replacement has install/connect/diagnostics but no corresponding firmware/updater implementation. | Missing app/service features. Do not invoke proprietary firmware tools or present inert commands as supported. |
| 3 | Undo/redo | Original nib declares standard Undo/Redo. Replacement controls do not register camera settings transactions with UndoManager. | No camera-setting undo implementation; original scope of Undo is unverified and could be limited to decorations/text. |

## Implemented interaction improvements in this pass

`StudioCommands` supplies File preset creation/import/management/switching, Settings, View aids/sidebar, and Camera mute, Face-lock, Lighting/Color/Effects clear and enable, and recording with loop-aware enablement. The exact archived shortcuts are:

| Action | Original archived shortcut | Replacement |
| --- | --- | --- |
| General preferences | Command-comma | Settings command |
| Show Zebra Lines | Shift-Command-L | Toggle zebra overlay |
| Show Histogram | Shift-Command-H | Toggle histogram |
| Show Sidebar | Command-/ | Toggle sidebar |
| Mute Video | Shift-Command-V | Stop/start camera |
| Preset creation/import/manage/switch | None in archive | No shortcut invented |

View actions are local notifications; overlays never enter outgoing camera pixels. Camera/module actions modify existing settings, so no new frame copy or processing stage was added. Preset selection continues using the existing explicit resolution restart path. New management methods save current image/sensor settings, rename, restore a saved snapshot, cycle selections, persist selected identity and clear identity after deleting its preset.

The menu intentionally calls snapshot restoration **Revert to Saved Settings**. Original `resetPreset:` exists, but whether it resets to factory defaults, a saved version, or another baseline is unverified. The label is explicit rather than claiming recovered semantics.

## Animation acceptance protocol

Root's UI comparison should record each event separately: expand/collapse Lighting, Color, Effects; Camera/Calls tab switch; show/hide sidebar; switch preset; hover/press a card control; enable/disable an effect; hold/release/stop a loop. Compare final layout, intermediate clipping, duration, curve, whether sibling cards move continuously, and whether preview geometry changes. Reduced Motion must suppress decorative movement. Scope animations to UI state changes so every camera frame does not trigger a view-wide animation or delay delivered pixels.

A screenshot establishes only final visual state. Static symbol strings can suggest an animation framework but do not establish curves, speed, transitions, or playback. Exact animation parity remains unverified until live interaction comparisons are recorded.

## Functional verification status

The version3 output delivery change and all earlier renderer/transport checks remain separate evidence from UI parity. Pacing tests prove immediate normal30fps delivery, burst spacing, 45ms stall repeat gating and monotonic timestamps; renderer tests preserve native detail and immutable/opaque frames at all three sizes. They do not validate menu, animation or original-effect equality. See `RUNTIME_VALIDATION.md` for actual version2/3 receiving-side results.

Validation for this pass: full `swift build -c release` passed; build log is `build/parity-commands-compile.log`. Runtime menu actions and animation comparisons are pending the root agent’s rebuilt UI pass.

This pass changes preset/menu behavior and the newly observed recording workflow; its screen/composition work stays separate from the meeting output pipeline. No original executable code, model weights, icon assets or shader binaries are added to the shipping app. No physical capture, firmware update, original-app setting change or network call was initiated by this audit subtask.


## End-of-pass disposition

The ranked table above records findings at the start of the audit. The resulting installed changes and verification supersede its “missing” labels as follows:

- Implemented and checked in native UI:sidebar/overlay shortcuts, multiple expanded cards, manual-row state/reset, white-point picker cancellation, preset create/rename/delete, loop hold/release/stop-clear semantics, separate recording options, audio/mode changes, camera-only record/start/finalize, and nested diagnostics presentation.
- Implemented and covered by deterministic/render tests:independent Bokeh, reconstructed selective-color interpolation, five custom looks, white-point correction, sensitivity smoothing, five resolutions and partial Composer preset codec.
- Added lifecycle controls and tested background close/reopen, restoring its original off preference. No login registration was enabled. Launch-at-login is API-backed but actual registration remains untested.
- Preset package transfer is explicitly partial; see PRESET_INTEROPERABILITY.md. Exact legacy effect scales and Composer-side acceptance are not claimed.
- Native Release build and strict/deep signature verification passed. Final suite:49core tests+7bridge tests,0failures (`build/final-audit-tests.log`).
- Extension version4 passed15-second synthetic1080p/1440p/360p receiving-side tests (452frames each,0pixel/timestamp/dimension faults,30fps). Live blurred1080p and a2.907second camera-only recording passed bounded checks. See RUNTIME_VALIDATION.md.
- Still unresolved:direct C1 runtime/physical focus, original dynamic Auto lighting, proprietary segmentation and bokeh response, exact original transition timing, automatic resolution and demand-based pause, fully terminated-app launch onUSBattach, original Both inset geometry, and actual screen/microphone recording acceptance. Meet/Zoom remote-session testing was not performed.

The requested two audit passes were performed and their concrete fixes installed. The broader exact-parity/zero-flicker objective is **not certified complete**; remaining gaps are explicit rather than represented by inert controls or fabricated test claims.
