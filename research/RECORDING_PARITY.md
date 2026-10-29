# Recording workflow reconstruction

October 29, 2026. Root's live original-app inspection established that the toolbar recording action opens a separate Recording window; it does not immediately ask for a filename and begin capture. The original window offers Screen, Camera and Both, microphone selection with an audio toggle, resolution and destination-folder selection, and a bottom record control. This finding supersedes the earlier assumption that camera-only file recording covered recording parity.

## Implemented

- `RecordingOptionsView` implements the observed 368×565 layout and three selectable modes. Default mode is Camera. The chosen mode, recording resolution, microphone identity and security-scoped destination-folder bookmark persist.
- Pressing Record starts the chosen mode. Choosing a tile or opening this window does not start capture. ScreenCaptureKit's shareable-content request is deferred until recording starts, so Screen Recording permission is only requested in the explicit Screen/Both recording flow.
- Camera mode uses the existing processed camera pixels; recording at a smaller size scales only the recording stream. A camera-only request above the current processed camera resolution is rejected rather than upscaled. Changing recording options does not restart or renegotiate the meeting camera.
- Screen mode records the explicitly selected connected display, including its visible windows/cursor. The default is the main display. Screen audio is not captured; the selected microphone is an independent optional AAC audio input.
- Both mode composites processed camera over the screen. **This layout is an independent reconstruction:** rectangular 30%-width inset at bottom right with a 2.5%-width margin. The original Both crop, shape, placement and interaction have not been observed.
- Screen/Both frames never enter the virtual-camera bridge or its preview. All screen capture, resizing, PIP composition and recording run on recording queues. Camera/meeting processing has only a bounded frame handoff.
- Short loops and file recording are mutually exclusive. Screen-only file recording can continue if the meeting camera is turned off. App shutdown cancels pending setup and joins finalization.
- Selected microphone lookup does not silently substitute another device if that selected device is missing. Permission/device errors are visible.

## Frame ownership and pacing

ScreenCaptureKit queue depth is3 and capture minimum interval is1/30. Only complete screen frames are accepted; one latest screen buffer and one latest camera buffer are retained. A separate30fps recording clock ensures a static desktop still records actual elapsed time and a moving camera inset continues updating. Repeated unchanged composition reuses the immutable completed result. A maximum four-buffer output pool bounds compositing allocations; a single pending FrameRecorder handoff bounds encoder backlog. Full-frame CI render completes before the output buffer is published to the encoder, and final alpha is forced opaque.

These behaviors follow Apple's [SCStreamOutput callback contract](https://developer.apple.com/documentation/screencapturekit/scstreamoutput) and [capture interval configuration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval), and the installed SDK's `SCStream.h`/`SCShareableContent.h`. The original app's recording implementation was not copied.

## Validation

`Tests/RecordingCaptureHarness/main.swift` compiles the production capture/composition and recorder sources with a test-only compositor entry point. It requests neither screen nor microphone permission and uses synthetic images only.

Passed checks (`build/recording-capture-check.log`):

- Full-frame opaque output and correct screen/camera inset content.
- Source mutation after render cannot alter the recorded output buffer.
- Four-buffer allocation limit and recovery when references release.
- Camera output1280×720 downscaled independently to640×360.
- Actual H.264 file start,30 changing frames, asynchronous finish, decode, exact640×360 track size, and both colors present after decoding.

Actual screen permission acceptance, native display capture, multi-display selection, live microphone/device changes, Both synchronization, long recordings and original Both layout equality remain unverified. No claims of successful screen/microphone runtime capture are made from synthetic tests. Root owns the rebuilt app's UI/runtime checks.

Native integration: `Window("Record", id: "recording") { RecordingOptionsView(studio: studio) }.windowResizability(.contentSize)` and toolbar `openWindow(id: "recording")`. `StudioCommands` already opens that window from its Recording item. App entitlement `com.apple.security.files.bookmarks.app-scope` is required for restoring the chosen recording folder.

## Secondary-panel follow-up — October 29, 2026

Fresh parent-agent observation confirmed the existing 368×565 logical-point layout: 104×68 mode tiles at x16/132/248, divider y206, audio card x16/y239/336×80, resolution card x16/y327/336×80, destination row y430, and 52-point record button centered at (184,514). Geometry was retained. Original Screen/Both tiles expose a yellow permission warning; `RequiresScreenPermission` in the installed app's `en.lproj/Localizable.strings` reads “Requires screen recording permission; it will be requested when starting.” `RecordScreenTitle` reads “Record Screen From.” These observations support the new warning badges and screen label. They do not establish the blocked Screen/Both expanded layout or composition geometry.

The warning now reflects read-only `CGPreflightScreenCaptureAccess()`, refreshed on activation; selecting a mode still never requests permission. Microphones refresh on activation and device arrivals/removals, and a disconnected explicitly selected microphone is shown as unavailable instead of displaying the system-default name while retaining a different recording identity. Audio enablement and selected display now persist alongside mode/resolution/microphone/folder.

Reviewed disabled states: recording/start/finalization disable mode, audio, resolution and destination controls. Record remains blocked during loop playback/capture/finalization and when Camera/Both have no active camera. Screen capture permission remains deferred until Record. Syntax parsing passed for modified sources; parent owns full build and live acceptance. No UI, camera, microphone or screen capture was initiated by this subtask.

No replacement preset-name dialog was introduced: fresh Composer menu observation showed New/Import/Export/Reset/Delete/Switch, but no confirmed rename dialog. The optional existing rename operation remains; a guessed custom panel would not establish parity.
