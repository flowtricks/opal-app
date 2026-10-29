# Native C1 input color boundary

## Proven shipped-code path

1. UVC output-settings constructor `0x10001bb40`: at `0x10001bba8`/`0x10001bbac`, FourCC is assembled as `0x34323076` (`420v`, video-range NV12). The dictionary is passed to `AVCaptureVideoDataOutput.setVideoSettings` at `0x10001bf78`.
2. Capture callback `0x1000105e4` obtains the CVPixelBuffer and calls `0x10000f588`, whose closure maps the planes through `0x100011550`.
3. At `0x1000115e0`, plane0 descriptor pixelFormat10 = R8Unorm; `0x100011620` maps plane0 directly through Core Video texture bridge. At `0x100011688`, plane1 format30 = RG8Unorm; `0x1000116bc` maps plane1. There is no YUV range or transfer conversion.
4. Callback `0x100010654` through `0x100010674` copies each plane to its shared texture. Metadata identifies `ImageHelpers.copyMetalTexture:toOtherMetalTexture:` implementation `0x100004888`; this labels its encoder "Blit one texture to another" at `0x1000048e0`, then blits. It does not render a color-conversion shader.
5. XPC `0x10002cf38` through `0x10002cf78` binds Y/UV images to `MTIImageConversionYUVToRGBA` and sets BGRA8Unorm output80.
6. Native AIR module9581 consumes normalized rawY and CbCr−0.5. Its matrix is R=Y+1.5748000144958496*Cr; G=Y−.18732400238513947*Cb−.46812400221824646*Cr; B=Y+1.8555999994277954*Cb. No subtraction16/255, no219/224 range expansion, no EOTF. The BGRA8 render target clamps/quantizes.

The original therefore does not use standard automatic video-range/color-management decoding at this boundary. Applying standard CIImage(cvPixelBuffer:) conversion, as Studio previously did, changes the incoming tonal distribution before any settings. This is a concrete explanation for deeper black/stronger contrast; visual equivalence still needs live comparison after integrating the native path.

## Implementation

CameraEngine now requests420v before420f/BGRA. `ComposerCameraInput.image(from:)` maps raw NV12 planes with CVMetalTextureCache and encodes the **actual bundled Composer YUV fragment** into a BGRA8Unorm texture on Core Image's existing GPU command buffer. A small GPU bridge converts the resulting encoded RGB to CI's linear working space; this preserves existing effect boundary conversions. Non-NV12 inputs use ordinary CIImage construction. It performs no CPU pixel readback, blocking wait, additional camera access, or separate command queue. Buffer/plane references stay retained through command completion.

The actual fragment supplies its original sampler, constants, and arithmetic. The helper vertex only provides the cropped normalized coordinate rectangle. Output/preview tagging has deliberately not been changed without full display-path proof.

## Other boundaries and bounded negative findings

Original UVC CI context sets workingFormat BGRA8, workingColorSpace DeviceRGB, and outputColorSpace DeviceRGB at `0x100010b44` through `0x100010c00`. XPC uses corresponding DeviceRGB options; its ToneSync CI bridge is being audited separately. Ordinary CI filters cannot be assumed equivalent to the encoded Metal stages solely because their names match.

Native RGB→YUV shaders use full-range709 equations: AIR13485 produces Y=.2126R+.7152G+.0722B, AIR5677 produces signed chroma+.5, without EOTF or limited-range scaling. This does not by itself establish the downstream virtual-camera buffer's metadata; no output-path change was made.

Native brightness is a physical camera intent: main `0x10027c40c` truncates rawDouble toInt32 then invokes setBrightness; UVCCameraDevice `0x1000066c4` conditionally disables brightness Auto and sets its control. No UVCCameraDevice setGamma or setHue methods are present in recovered Objective-C methods; those selector names in UVCDeviceProperties refer to stored control-object accessors. White-balanceGr/Gb methods are getters. These bounds do not prove that every possible initialization path has no additional write; they provide no basis for speculative gamma/hue/GrGb reset writes.

## Validation

`swift build --target OpalCoreTests` passes. Three `ComposerCameraInputTests` pass using the actual bundled fragment: five independently computed raw-YUV vectors including native raised black/limited white, full-versus-cropped rendering, and bilinear4:2:0 chroma sampling. Native input conversion at720p measured median1.17ms / max1.83ms over8 warmed renders including the test-onlyCPUbitmap readback. This is an isolated input-stage measure, not end-to-end camera latency. Logs: `build/native-input-library-build.log`, `build/native-input-library-tests.log`.
