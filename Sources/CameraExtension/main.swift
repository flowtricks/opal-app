import Foundation
import CoreMediaIO

let cameraProvider = StudioProvider()
CMIOExtensionProvider.startService(provider: cameraProvider.provider)
CFRunLoopRun()
