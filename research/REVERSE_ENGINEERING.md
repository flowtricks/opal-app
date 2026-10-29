# Opal Composer investigation

Inspected October 29, 2026. Target: the user's installed `/Applications/Opal Composer.app`, with an Opal C1 camera. The reported defect is intermittent white boxes and apparent opacity flicker in conference applications. No failure recording or live reproduction was captured in this investigation. **The root cause and elimination of the flicker remain unverified.**

## Scope and method

Used the requested [morluto/rea skill](https://github.com/morluto/rea), installed at commit `1da304b28213ca7a50f6787eae716abe73c4e628`, skill metadata version 55. Used REA CLI `rea-agents@6.8.0` for app/extension metadata, native Mach-O imports and layout, and compiled Interface Builder resources. The npm integrity declaration was `sha512-9QDeRnGqEDzABZyr04eLnBXBv/c6I9/TWu/6M0MD4pEfkySI/BIgwTODIbAReX3C1x6hjw9+Jlx4A2yUSPZ9ww==`. The first pass used resource/static inspection. A later pass installed Ghidra 12.1.4 and Temurin 21 locally under `.analysis-tools/`, built the native arm64 decompiler, and used REA through a temporary native-analysis session. There was no global tool registration, modification of the original app, or credential inspection.

REA resource evidence alone does not recover function bodies. The subsequent Ghidra pass did recover selected native procedures in `OpalCameraVideoService`, exporting 33 evidence records before closing the session. The universal executable was thinned into an analysis-only arm64 slice because the provider could not enforce an architecture on the universal file. The initial provider-error receipts are historical attempts, not the final capability status. LLVM/AIR shader modules were also decoded locally with llvmlite 0.50.0. See [the detailed effects report](effects/README.md) for source hashes, tool provenance, recovered math, and limitations.

Supplementary `strings`, `nm`, `otool`, `plutil`, Python parsing, LLVM/AIR decoding, and `system_profiler` results are **ordinary static observations**, not automatically REA Evidence. Decompiled bodies are static interpretations, not traces of execution or proof of runtime parity.

## Identity and evidence index

| ID | Evidence | Result / boundary |
| --- | --- | --- |
| R1 | [rea-plist.json](rea-plist.json), REA `ev_7cfef42a7d700d8c1b1b1d18a3e421cd3145685c572cb53161c49c569543f039` | App 2.0, build 24, bundle `com.opalcamera.Opal.v2`, SDK macOS 14.5, minimum macOS 13. Resource-only evidence has null executable identity. |
| R2 | [rea-extension-plist.json](rea-extension-plist.json), REA `ev_88bb66f116cd34b80dfb33448e1f53326014ddda1ebab858342c818dd3cb9707` | Embedded CoreMediaIO system extension, version 1.1.2 build 24, protocol version 8. |
| R3 | [rea-macho.json](rea-macho.json), REA `ev_a36ff2c5a14f73c522806f7a12cc3cb335f2c583e8914b5f2aa91475ae237be8` | Universal x86_64/arm64 executable; arm64 dependency/import/export layout. Stripped or toolchain-hidden symbols may be absent. |
| R4 | [rea-interface-builder.json](rea-interface-builder.json), REA `ev_520046d0ccd80902ba4c644e0b61baa137fa823a30f52c2a1fcbfd6be432bdc8` | Eight compiled UI archives decoded, including the main menu; bounded traversal, 18 symlinks not followed, unrecognized archive fields unknown. [Selected menu actions](rea-main-menu-summary.json) are a projection of this evidence. |
| R5 | [Native evidence bundle](effects/rea-evidence-bundle.json), [export receipt](effects/export-receipt.json), [close receipt](effects/close-receipt.json) | 33 Ghidra 12.1.4 REA records tied to the analysis-only arm64 video-service slice; selected procedure bodies, calls and references. Session closed after export. |
| R6 | [Touch Up curve](effects/touchup-curve.json), REA `ev_4611ac6888f924f09391e31c0e7dd68b03963377b8079603063f1df4f20f9d32`; [Tone Sync filter body](effects/skin-filter-image.json), REA `ev_08d36fb364ed1fc71769a574766162ea0de7ed4066a03187d973e73c8c48d7cc` | Specific recovered control-point and `CIFaceBalance` procedures. Other related native evidence is indexed in the effects report. |
| E1 | [AIR module manifest](effects/air/manifest.json), [effects report](effects/README.md) | Ordinary local LLVM/AIR decoding records library/module hashes and offsets; supports shader-equation reconstruction. No vendor kernel executed by this analysis. |
| S1 | [static-manifest.json](static-manifest.json) | Independently hashed executable files, linked metadata, parsed packaged filter JSON and preset inventory. |
| S2 | [app-selected-strings.txt](app-selected-strings.txt) | Selected feature identifiers, Objective-C selectors, and diagnostics. Shader implementation text excluded. |
| S3 | [extension-selected-strings.txt](extension-selected-strings.txt), [extension-imports.txt](extension-imports.txt) | Extension selectors and undefined imported symbols, arm64. |
| S4 | [app-linked-libraries.txt](app-linked-libraries.txt), [extension-linked-libraries.txt](extension-linked-libraries.txt) | Dynamic link declarations, not runtime invocation traces. |
| S5 | [ui-feature-labels.json](ui-feature-labels.json), [bundled-preset-settings.json](bundled-preset-settings.json) | Packaged UI labels and preset settings, not user's personal settings. |
| S6 | [cameras.txt](cameras.txt) | macOS lists both Opal Composer and physical Opal C1, the latter with a UVC model identifier. |

The main executable SHA-256 is `d8e4dae9b6fe87acb8a51913a15245125454e6e17de6cc924941787d457eac27`; the camera extension SHA-256 is `4c856f2449e9f91574c8bc5842bfc487197767bbc65d3ef123b317eb0fe3a168`. These bind the shell observations to this installed version. They do not authenticate the software or establish that another version behaves identically.

## Observed feature inventory

| Feature | Evidence | Reconstruction implications |
| --- | --- | --- |
| Background blur / Bokeh | S5 Bokeh label; A1/A4 bundled presets enable bokeh with value 8.48; S2 segmentation, mask, and hexagonal-bokeh identifiers | Preserve adjustable subject-aware background blur. Matching a proprietary segmentation model or bokeh response exactly has not been established. |
| Exposure, contrast, saturation, white balance, temperature | S5 labels and S2 setters/models | Recreate independent controls. Separate digital exposure from sensor exposure; these are not interchangeable. |
| Selective color adjustments | S2 `setHSV...DistortionWithHue:andSaturation:andBrightness:` for red, orange, yellow, green, aqua, blue, purple, magenta | Full parity includes per-color controls beyond global saturation/warmth/tint. |
| Filters | S1 packaged JSON explicitly names `CIPhotoEffectTonal`, Chrome, Instant, Transfer, Process, Fade, Noir, Mono, plus custom G1/D1/Q1/X1/S1 identifiers | The eight standard Core Image filters are directly identifiable. Five custom shader mappings and RGB equations have now been recovered and independently implemented; see [custom-look evidence and precision limits](filters/README.md). |
| Zoom, focus distance, Face-lock | S5 labels; S2 face tracking, face zoom, face-based autofocus/exposure identifiers | Basic cropping is distinct from tracked face framing and physical focus. Physical controls are implemented independently through the public DepthAI SDK; original calibrated focus-distance units and exact face-control policy are not recovered. |
| Touch Up | R5/R6 and E1 identify guide/high-pass/detail-protection math, radius 8 and a natural cubic tone curve | Independent Core Image reconstruction and render tests now exist. MPS/Core Image precision, quantization and segmentation differences prevent a claim of identical pixels. |
| Tone Sync | R5/R6 identify `CIFaceBalance`, `inputStrength=2*amount`, warmth, YIQ calibration, skin extraction and person-mask blending | Reconstructed with the observed calibration/math and tests. Availability is checked because the filter identifies itself as Apple-private; no guessed fallback effect. |
| Backgrounds | S5 module label and preset settings | Custom background replacement is a separate effect from blur. |
| Stickers | S5 face attachment, horizontal/vertical flip, layer switching, size, deletion labels | Static or face-attached overlays, foreground/background compositing. Exact tracking behavior remains unobserved. |
| Loops and recording | S5 hold-to-record, release-to-play, stop-to-clear labels and recording interlocks; R1 app keywords | Full parity includes recording and loop playback, with restrictions while recording. |
| Presets | R1 registered preset/settings document types; S1 packaged presets | Independent replacement preset format can preserve own settings; original format compatibility requires further schema work. |
| Antibanding | S5 Auto/50 Hz/60 Hz/Off labels | Intended for illumination banding. It is not an established fix for arbitrary white blocks or alpha artifacts. |
| Resolution and lifecycle | S5 auto/manual resolution, pause when not streaming, background operation, and camera mute labels | A fixed format is an intentional stability design choice, not exact behavior parity with Composer's automatic format selection. |

Opal's official documentation corroborates [segmentation-based bokeh, backgrounds, Face-lock and face-attached stickers](https://support.opalcamera.com/faqs/uDDK4A1Tm7ShrLx98tHYAe/why-am-i-missing-some-opal-composer-features-on-my-intel-mac/8BeBeWnsdFhocjvDuRjGaK). Its [settings guide](https://support.opalcamera.com/getting-started/fkAzVQUCbZUpDSf1awyP3k/opal-composer-app-settings/ohDfrU174FBc7rMj1YBTbN) describes antibanding and automatic/manual resolution. These web documents are corroboration, not proof of every behavior in build 24.

R4 directly observes main-menu target-action entries for creating, importing, exporting, resetting, deleting and switching presets, saving logs, opening settings and firmware updates. Archive action declarations do not prove their implementation or current visibility; no action was invoked. Dynamic effects UI is not fully represented by these menus.

## Pipeline findings

**Observed:** The app links AVFoundation, CoreImage, Metal, MetalPerformanceShaders, IOSurface, CoreMediaIO, `libusb`, and `libdepthai-core` (S4). Its embedded strings include MetalPetal type names, pixel-buffer-pool exhaustion diagnostics, Core Image fallback for buffers lacking IOSurface backing, and IOSurface rendering errors (S2). It contains segmentation scheduling and mask-compositing identifiers.

**Observed:** The camera extension imports `CVPixelBufferCreateWithIOSurface` and `CMSampleBufferCreateForImageBuffer` and contains `sendSampleBuffer:discontinuity:hostTimeInNanoseconds:` (S3). Its plist declares a CoreMediaIO mach service (R2). The app includes separate UVC and InFocus XPC service bundles (S1 inventory boundary: main app contents).

**Inference:** A hardware acquisition/control layer feeds a GPU effects/compositing stage, and processed image surfaces reach a system camera extension for delivery to clients. A separate app-side preview exists. The selected video-service effect procedures and shader equations are now recovered in more detail: Touch Up is a high-pass/detail-protected tone-curve blend, and Tone Sync uses calibrated `CIFaceBalance` with person-mask blending. The complete original acquisition-to-extension threading, ownership, timing, pixel formats, mask synchronization, and buffer reuse policy remain unresolved. Imports alone do not prove those relationships.

The physical C1 source and the virtual Composer source are separate devices. Opal explicitly documents that [C1 is the raw camera feed and Composer includes its effects](https://support.opalcamera.com/getting-started/fkAzVQUCbZUpDSf1awyP3k/using-your-opal-camera-in-video-conferencing-apps/rcqJpScnUj1ZXmE5KK9knb). A replacement can acquire the UVC source and publish its own processed camera rather than depend on Composer's output. The replacement now contains stock UVC and an optional direct DepthAI backend with exact-device selection and passive discovery. Direct controls temporarily replace the camera RAM runtime and disconnect stock camera/microphone functions; actual sensor response and restoration still require a dedicated hardware test. See [hardware options](HARDWARE_CONTROL_OPTIONS.md), [backend provenance](../Sources/C1Bridge/README.md), and [the enumeration correction](C1_ENUMERATION_AUDIT.md).

## Flicker hypotheses and safeguards

None of these is a diagnosis of the original app. They are bounded engineering hypotheses motivated by the symptom and observed pipeline components.

| Hypothesis | Discriminating evidence needed | Replacement safeguard |
| --- | --- | --- |
| A consumer reads a buffer while the producer/GPU is still modifying it | Capture stage-by-stage checksums and GPU completion/buffer lifetime events during an artifact | Publish only complete, immutable output frames. Do not return a buffer to a writable pool while a downstream consumer can still use it. |
| Undefined/incorrect alpha or uninitialized regions appear as opacity changes or blocks | Inspect BGRA bytes, alpha histogram, crop bounds and format at the failing stage | Render the entire fixed output extent, force opaque final alpha, and validate dimensions/stride/format. |
| Segmentation or mask state changes cause opacity jumps | Save synchronized input/mask/output locally during a reproduced failure | Smooth mask transitions and hold the last valid mask on transient segmentation failure; expose stale-mask diagnostics. |
| Output timestamps, format changes, or producer stalls disrupt consumers | Log PTS, output intervals, device-format changes, queue lengths and drops | One fixed negotiated output format, monotonically increasing host-clock PTS, bounded queues and repeat the last complete frame on short stalls. |
| Camera firmware, UVC delivery, USB connection, or lighting already corrupt the raw image | Compare raw C1 output with processed output under the same conditions | Report capture failures; avoid claiming an app-only pipeline can repair arbitrary corrupted input or hardware faults. |
| Conference app or GPU driver adds the defect | Compare a local recording of virtual output with the receiving side of Meet/Zoom | Validate actual client output; test consumer effects and acceleration independently. |

Apple requires sample timestamps relative to the stream's declared clock and identifies host time as the capture time in [CMIOExtensionStream.send](https://developer.apple.com/documentation/coremediaio/cmioextensionstream/send(_:discontinuity:hosttimeinnanoseconds:)). CPU pixel access requires matching lock/unlock flags in [CVPixelBufferLockBaseAddress](https://developer.apple.com/documentation/corevideo/cvpixelbufferlockbaseaddress(_:_:)). Those rules support the proposed implementation constraints; they do not show that Composer violates them.

## Acceptance work still required

1. Record raw C1, original Composer preview/output, and replacement preview/output under the same lighting, movement and settings. Include the white-box/opacity defect if it can be reproduced.
2. Verify that blur is maintained while moving, entering/leaving frame, changing color settings, and briefly delaying segmentation. Measure mask age rather than silently interpreting every repeated frame as success.
3. Exercise dropouts, camera unplug/replug, stop/start, app backgrounding, two camera consumers, and sustained CPU/GPU load. Confirm there is no queue growth or frame-buffer mutation after publication.
4. Inspect output byte values and timestamps automatically, then run at least a 30-minute Meet session and a 30-minute Zoom session with the installed virtual camera. Confirm the remote receiver's image, not only a local preview.
5. Repeat the user's normal meeting workflow and separately test additional conference-app blur/background effects. Report observed artifacts, repeated/stale frames, effective frame rate, and maximum delays.
6. Close the explicit gaps in [the feature parity matrix](FEATURE_PARITY.md) with controlled reference comparisons; implementation and synthetic tests alone do not establish exact Composer parity.
7. Prioritize the user’s newly reported preview delay: compare capture age, segmentation time, processing time, output repeats and browser decoded rate. The replacement now has a direct Metal preview, bounded GPU work, separate low-frequency thumbnails, and asynchronous bounded recording. These are implemented latency safeguards, not a measured claim that every delay has been removed.

Checklist status: app identity **answered**; visible feature inventory **partially answered**; output architecture **partially answered**; Touch Up/Tone Sync algorithms **substantially recovered with documented differences**; custom-filter equations **recovered and render-tested**; proprietary model/full-pipeline pixel parity **unresolved**; flicker root cause **unresolved**; end-to-end replacement stability **unresolved** until runtime acceptance is performed.

## Reproduction commands

Run REA commands from a trusted directory outside the target app/project, as the skill specifies:

```sh
npx -y rea-agents@6.8.0 inspect-plist '/Applications/Opal Composer.app' --format json --full-output
npx -y rea-agents@6.8.0 inspect-plist '/Applications/Opal Composer.app/Contents/MacOS/Opal Camera Setup.app/Contents/Library/SystemExtensions/com.opalcamera.Opal.v2.opalCameraExtension.systemextension' --format json --full-output
npx -y rea-agents@6.8.0 inspect-macho '/Applications/Opal Composer.app' --format json --full-output
npx -y rea-agents@6.8.0 decode-interface-builder '/Applications/Opal Composer.app' --max-documents 8 --max-objects 2000 --max-connections 4000 --format json --full-output
otool -arch arm64 -L '/Applications/Opal Composer.app/Contents/MacOS/Opal Composer'
strings -a '/Applications/Opal Composer.app/Contents/MacOS/Opal Composer'
xcrun nm -arch arm64 -u '/Applications/Opal Composer.app/Contents/MacOS/Opal Camera Setup.app/Contents/Library/SystemExtensions/com.opalcamera.Opal.v2.opalCameraExtension.systemextension/Contents/MacOS/com.opalcamera.Opal.v2.opalCameraExtension'
plutil -p '/Applications/Opal Composer.app/Contents/Resources/en.lproj/Localizable.strings'
system_profiler SPCameraDataType
```

Research now retains static metadata, decompiled procedure evidence, decoded LLVM/AIR modules, and public-source references for analysis. Those research artifacts and vendor implementations are not compiled or linked into the replacement. Production effects are independently written from the observed math using system filters; Composer’s binaries, neural-network weights, graphics assets and shader library are not shipped. The separate public DepthAI SDK/runtime dependency is documented with its pins and notices in [the C1 backend README](../Sources/C1Bridge/README.md).

See [C1 hardware-control options](HARDWARE_CONTROL_OPTIONS.md) for public source references that can provide manual focus independently of Composer, with materially different capture behavior.
