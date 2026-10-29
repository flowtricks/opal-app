import AppKit
import UniformTypeIdentifiers
import OpalCore

/// Safe, bounded package I/O. Resource images and sticker/background data are never read.
enum ComposerPresetFiles {
    static let contentType = UTType(importedAs: "com.opalcamera.opb", conformingTo: .package)
    static func read(_ url: URL, base: CameraSettings) throws -> ComposerPresetCodec.Imported {
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        guard root.pathExtension.lowercased() == "opalpreset", try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ComposerPresetCodec.Invalid.document("Choose an .opalPreset package or an Opal Studio JSON file.")
        }
        func readMember(_ name: String, required: Bool) throws -> Data? {
            let member = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            guard member.path.hasPrefix(root.path + "/") else { throw ComposerPresetCodec.Invalid.document("Preset member points outside its package.") }
            if !FileManager.default.fileExists(atPath: member.path) && !required { return nil }
            let info = try member.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= ComposerPresetCodec.maximumDocumentBytes else {
                throw ComposerPresetCodec.Invalid.document("Preset settings must be regular files no larger than 2 MB.")
            }
            return try Data(contentsOf: member)
        }
        return try ComposerPresetCodec.decode(settingsData: readMember("data.opaldata", required: true)!,
            metadataData: readMember("preset.settings", required: false), fallbackName: root.deletingPathExtension().lastPathComponent, base: base)
    }
    static func write(_ exported: ComposerPresetCodec.Exported, to url: URL) throws {
        let package = FileWrapper(directoryWithFileWrappers: [
            "data.opaldata": FileWrapper(regularFileWithContents: exported.settingsData),
            "preset.settings": FileWrapper(regularFileWithContents: exported.metadataData),
            "stickers.opalstickers": FileWrapper(regularFileWithContents: exported.stickersData)])
        try package.write(to: url, options: .atomic, originalContentsURL: nil)
    }
}

final class PresetExportAccessory: NSObject {
    let view: NSStackView
    private let popup = NSPopUpButton()
    private weak var panel: NSSavePanel?
    var isComposer: Bool { popup.indexOfSelectedItem == 1 }
    init(panel: NSSavePanel) {
        self.panel = panel
        let label = NSTextField(labelWithString: "Format")
        let note = NSTextField(wrappingLabelWithString: "Composer transfers supported settings only; retained original fields may differ from the current look.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        popup.addItems(withTitles: ["Opal Studio JSON — all settings", "Opal Composer — partial transfer"])
        let row = NSStackView(views: [label, popup]); row.orientation = .horizontal
        view = NSStackView(views: [row, note]); view.orientation = .vertical; view.alignment = .leading
        view.spacing = 8; view.frame = NSRect(x: 0, y: 0, width: 420, height: 65)
        super.init()
        popup.target = self; popup.action = #selector(changeFormat)
    }
    @objc private func changeFormat() {
        guard let panel else { return }
        let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.allowedContentTypes = isComposer ? [ComposerPresetFiles.contentType] : [.json]
        panel.nameFieldStringValue = stem + (isComposer ? ".opalPreset" : ".json")
    }
}
