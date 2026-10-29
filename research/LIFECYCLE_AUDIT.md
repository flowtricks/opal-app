# Application lifecycle audit

The installed Composer2.0 resource strings explicitly contain:

- `SettingsGeneralStartupAppAtLogin`: “Start app at login”.
- `SettingsGeneralStartupWhenCamera`: “Start when camera is plugged in”.
- `MenuBarShowExtraToggle`: “Show in menu bar”.
- `MenuBarAllowRunningInBackground`: “Allow running in background”.
- `MenuBarDescription`: the menu-bar app remains accessible after closing the main window and runs without activating the camera until an external app uses it.
- `SettingsVideoPauseInBackground`: “Pause video when not streaming”.
- Auto-resolution text promises adaptation to the consuming app; it does not expose the algorithm.

Source: `/Applications/Opal Composer.app/Contents/Resources/en.lproj/Localizable.strings` and bundled utility/UI localizations, read with `plutil`. No original preferences were changed.

`Sources/OpalApp/StudioLifecycle.swift` implements explicit login-item registration through `SMAppService.mainApp`, current approval/status reporting, a menu-bar item with camera/open/settings/background/quit actions, persisted menu/background settings, and optional reveal-on-device-connection while the app is already running. Background defaults off; login registration is never changed merely by reading settings. Superseded by the October 29 automatic-start follow-up below: capture now starts once on application launch. The menu never silently swaps the selected camera or alters its resolution.

## Required integration

The root app owns the lifecycle instance for the whole process. Add a `@StateObject private var lifecycle = StudioLifecycle()` beside StudioModel. Give the main WindowGroup an ID, e.g. `WindowGroup(id: "main")`, pass the lifecycle to the root view, and have the root view attach it once its `openWindow` action is available:

```swift
// Root view property:
@ObservedObject var lifecycle: StudioLifecycle
// Root view modifier:
.onAppear { lifecycle.attach(studio: studio) { openWindow(id: "main") } }
```

In the App's existing onAppear assign `appDelegate.lifecycle = lifecycle` as well as its existing studio reference. In `StudioAppDelegate`, retain a weak lifecycle property and add:

```swift
weak var lifecycle: StudioLifecycle?
func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    lifecycle?.terminateAfterLastWindowClosed ?? true
}
func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { lifecycle?.openMainWindow() }
    return true
}
```

The existing `applicationShouldTerminate`/`StudioModel.shutdown` path must remain, so Quit and closing the last window with background disabled safely finalize recordings and close hardware. Closing a window in background mode leaves an already-started stream running; it does not activate an idle camera.

Preference bindings:

```swift
Toggle("Start app at login", isOn: Binding(get: { lifecycle.launchAtLogin }, set: lifecycle.setLaunchAtLogin))
Text(lifecycle.loginStatusMessage)
if lifecycle.loginRequiresApproval {
    Button("Open Login Items Settings") { lifecycle.openLoginItemsSettings() }
}
Toggle("Show in menu bar", isOn: $lifecycle.showInMenuBar)
Toggle("Allow running in background", isOn: $lifecycle.allowRunningInBackground)
Toggle("Show window when an Opal camera connects", isOn: $lifecycle.showWhenCameraConnects)
```

## Explicit remaining limits

The last toggle is deliberately described as showing an *already-running* app. Launching a fully terminated app on USB attachment requires a separately installed helper/agent that monitors device arrival; this controller does not provide one and must not be labeled as equivalent to Composer's complete “Start when camera is plugged in” feature.

Automatic capture start/stop based on external-consumer demand and automatic resolution selection are not inferred from resource descriptions. This helper does not claim those policies. The current stream stays running when its window closes in background mode. No login item was registered during implementation/testing; real registration/approval depends on the installed signed app and the user's explicit toggle.


## Automatic startup follow-up — October 29, 2026, 15:47

The user explicitly requested automatic camera startup. Lifecycle attachment now requests capture once per process. StudioModel retains desired capture state and uses one two-second timer, with a 250 ms tolerance, to retry failed stock-camera startup. Attempts do not overlap in-flight capture, do not invoke the direct USB backend, and wait for authorized camera access and the selected device. Manual Camera Off and shutdown cancel the timer. Changing resolution or selected device preserves the previous requested state. Opening another window does not override a manual stop.

Installed signed-app checks: launch started capture without a Start click; exclusive C1 ownership by Composer produced a waiting state without a Start button; after Composer camera-off/quit and its helper released USB, capture became live automatically. Composer’s helper can retain USB after its main process exits, so the release itself is outside Studio’s control. No helper was killed or camera reset performed. Manual Off stayed off through navigation and subsequent UI checks. Fresh launches twice started live capture automatically. Permission-denial and physical USB unplug scenarios were not exercised in this pass.

## Login and camera plug-in launch implementation — October 29, 2026

The user requested both launch behaviors to match Composer. `StudioLifecycle` now registers a bundled `SMAppService.agent` for “Start when camera is plugged in”; its state and OS approval errors are separate from the existing `SMAppService.mainApp` login setting. Changing the setting unregisters the agent when off. Merely opening settings does not register either service. The parent integration enables both through the installed app after verification.

`Sources/CameraLaunchAgent/main.swift` uses `IOServiceAddMatchingNotification` on `IOUSBHostDevice`, constrained to C1 stock VID `03e7`, PID `f63d`, and product name `Opal C1`. It only reads registry metadata. It never obtains a USB device interface, requests camera access, captures frames, or changes firmware. A matching arrival schedules the containing signed app through `NSWorkspace` after 750 ms. The app path is derived from the helper’s bundle location and validated against the expected bundle identifier. Initial registry matches are drained without launching: quitting Studio while the camera stays connected does not restart it. The helper has no polling timer; `launchd` keeps it available in the current Aqua session independently of the main process. Unregistering removes this behavior. It does not watch unrelated camera models or the virtual extension.

The Xcode generator builds/signs a dedicated `OpalCameraLaunchAgent` tool target, embeds it at `Contents/MacOS/OpalCameraLaunchAgent`, and embeds the registration plist at `Contents/Library/LaunchAgents/com.timothyricks.opal-app.camera-launch.plist`. This uses the modern bundle-relative `BundleProgram` API, with no arbitrary launch-agent file written into the user’s Library.

Validation: helper Release target compiled successfully (`build/xcode-camera-launch-agent.log`). A two-second passive `--observe-only` launch successfully registered its notification and stayed alive at 0.0% CPU and 8704 KiB RSS; the test process was terminated cleanly. This did not open the main app, register a persistent service, or touch camera ownership. Physical unplug/replug and next-login launch require installed-service validation; the passive test does not claim those outcomes.

Implementation sources: Apple’s `SMAppService.h` in the installed macOS 27 SDK, [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [register](https://developer.apple.com/documentation/servicemanagement/smappservice/register()), and [bundle-relative helper migration](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos). These document signed bundled LaunchAgents, `BundleProgram`, `Contents/Library/LaunchAgents`, and status/approval semantics. Composer’s original lifecycle is still supported only by the resource observations recorded above; no unseen launch policy is claimed.

## Replug duplicates and original C1 loading video — October29 follow-up

The arrival helper previously always called openApplication at its enclosing app path. It now first finds an already running `com.timothyricks.opal-app` by bundle identity (including another installed copy), posts the narrowly scoped reveal-main notification, and activates it. If no instance exists, it asks LaunchServices to reuse rather than create a new instance. The app also declares LSMultipleInstancesProhibited and detects an older peer on startup. The main SwiftUI scene changed from WindowGroup to singleton Window, preventing repeated reopen actions from creating another main window in the same process. Reopen does not override a manual camera-off choice.

Read-only launchctl inspection also confirmed the original Composer helper `com.opalcamera.v2.Opal.OpalLaunchHelperTool` was still running as PID1300 under parent `com.opalcamera.Opal.v2`, version24, while the replacement helper was running separately. Original launchOnLogin was false. The parent observed the distinct original Composer app launch on replug; this is a second application, not merely a second replacement window. The integration owner is addressing the original plug-in startup option through its own settings. This subtask did not modify original application preferences or terminate its helper.

The rotating C1 loader is a shipped movie, not a guessed 3D mesh: `/Applications/Opal Composer.app/Contents/Resources/1_C1_Spin_black.mp4`, HEVC850×850,60fps,15.016667seconds. With user authorization to match that loader, the identical resource is bundled as `Resources/ComposerC1Loading.mp4` (SHA256 `8ac7c6f97d6e19ffb52f87b4382c0fd9756047d77ba3d24b76eef4ad43397ed8`). Its frame was inspected locally. `ComposerCameraLoadingView` loops via AVPlayerLayer only while the requested camera has no live preview. SwiftUI removal stops playback, disables looping, removes queued items, and disconnects the layer; there is no continuing animation work once video appears. Reduce Motion pauses it. This reproduces the spin clip; no guessed twist/end-loop transition delays the live camera.

Validation: helper Swift typecheck and App Info plist lint pass. Full suite passed56 Core and10 CameraBridge tests after the loader/single-window changes. Installed UI/replug behavior remains for the parent integration verification.

## Replug capture recovery serialization

Read-only audit found three independent full-session rebuild entry points: device-connected notifications, interruption-ended notifications, and watchdog recovery. They previously lacked a shared in-flight guard, so a replug could enqueue competing stop/remove/re-add operations. Physical disconnect also left `isRunning` true, which prevented physical-control subscribers from releasing their handles. The separate2-second startup retry already respects `isCaptureRequested`; lifecycle reappearance is guarded by `didStartAutomatically`, so neither explains repeated reopen capture starts. No16.7-second timer exists in these capture paths; the observed firmware USB reset period is not attributed to this race without runtime confirmation.

`CaptureConfigurationGate` now coalesces session rebuilds and invalidates stale completion/status callbacks after disconnect or a later configuration. Reconnection waits0.5seconds for enumeration; watchdog recovery is paused during that debounce, configuration, or physical absence. Interruption-ended leaves AVFoundation's own resume alone and relies on the watchdog only if frames actually remain stale. Disconnect publishes source `isRunning=false` while preserving capture-request intent and the output timer, which continues bounded last-frame retention then privacy slate. Capture and hardware writes reject absent/stale sources. These changes contain no visibility-based stop. The parent integration retains the virtual bridge during requested-source interruptions and manages App Nap separately.

Four new tests cover concurrent request coalescing, old completion invalidation, main-queue status staleness, and retry-budget preservation during physical absence. Installed USB replug stability remains a runtime verification requirement, particularly for the separate stock-control changes.

A final startup timing fix resets the source-frame grace baseline after blocking `AVCaptureSession.startRunning()` returns. Previously a slow USB session start could consume the entire2-second watchdog grace before the new stream had any chance to deliver a frame, causing immediate unnecessary recovery. The old source timestamp is cleared when reconfiguration starts; a fresh frame already received during startup is preserved.
