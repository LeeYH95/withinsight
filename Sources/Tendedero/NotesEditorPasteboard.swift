import AppKit
import NotesCore

enum NotesEditorImport {
    case file(URL)
    case image(Data)
}

@MainActor enum NotesEditorDrop {
    static func load(_ providers: [NSItemProvider]) async throws -> [NotesEditorImport] {
        var result: [NotesEditorImport] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                let url: URL = try await withCheckedThrowingContinuation { continuation in
                    _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                        if let url = object as? URL { continuation.resume(returning: url) }
                        else { continuation.resume(throwing: error ?? NotesStoreError.invalidSource) }
                    }
                }
                result.append(.file(url))
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                    _ = provider.loadObject(ofClass: NSImage.self) { object, error in
                        if let image = object as? NSImage { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? NotesStoreError.invalidSource) }
                    }
                }
                guard let bytes = NotesEditorPasteboard.pngData(image) else { throw NotesStoreError.invalidSource }
                result.append(.image(bytes))
            }
        }
        return result
    }
}

/// Clipboard image representations are alternatives per item, not separate pictures.
@MainActor enum NotesEditorPasteboard {
    static let copiedImageType = NSPasteboard.PasteboardType("local.shipian.copied-image")
    static func imports(from board: NSPasteboard) -> [NotesEditorImport] {
        var result: [NotesEditorImport] = []
        for item in board.pasteboardItems ?? [] {
            if let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL { result.append(.file(url)) }
            else if let png = item.data(forType: .png), NSImage(data: png) != nil { result.append(.image(png)) }
            else if let tiff = item.data(forType: .tiff), let image = NSImage(data: tiff), let png = pngData(image) { result.append(.image(png)) }
        }
        if result.isEmpty, let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] { return urls.map(NotesEditorImport.file) }
        return result
    }
    static func images(from board: NSPasteboard) -> [Data] {
        (board.pasteboardItems ?? []).compactMap { item in
            if let png = item.data(forType: .png), NSImage(data: png) != nil { return png }
            if let tiff = item.data(forType: .tiff), let image = NSImage(data: tiff) { return pngData(image) }
            return nil
        }
    }
    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    @discardableResult static func writeImage(_ data: Data, to board: NSPasteboard) -> Bool {
        guard let image = NSImage(data: data), let png = pngData(image) else { return false }
        board.addTypes([.png, .tiff, copiedImageType], owner: nil)
        board.setString("1", forType: copiedImageType)
        let wrote = board.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation { _ = board.setData(tiff, forType: .tiff) }
        return wrote
    }
}

extension NotesEditorSession {
    @discardableResult func copyAttachment(_ attachment: NoteAttachment, to board: NSPasteboard = .general) -> Bool {
        do {
            let data = try Data(contentsOf: localURL(for: attachment))
            guard attachment.kind == .image, NSImage(data: data) != nil else { throw NotesStoreError.invalidSource }
            board.clearContents()
            guard NotesEditorPasteboard.writeImage(data, to: board) else { throw NotesStoreError.invalidSource }
            return true
        } catch { reportAttachmentFailure("图片未能复制：" + error.localizedDescription); return false }
    }
}
