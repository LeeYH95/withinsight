import Foundation

public enum NoteTemplate: String, CaseIterable, Codable, Sendable { case text, checklist, image }
public enum NotePaper: String, CaseIterable, Codable, Sendable { case plain, blue, lavender, rose, warm, gray }
public enum NoteScope: String, CaseIterable, Sendable { case all, onLine, offLine, trash }

public struct NoteBlock: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case paragraph, checklist, image, file }
    public var id: UUID
    public var kind: Kind
    public var text: String
    public var richText: Data?
    public var markdown: String?
    public var isChecked: Bool
    public var attachmentID: UUID?
    public init(id: UUID = UUID(), kind: Kind = .paragraph, text: String = "", richText: Data? = nil, markdown: String? = nil, isChecked: Bool = false, attachmentID: UUID? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.richText = richText
        self.markdown = markdown; self.isChecked = isChecked; self.attachmentID = attachmentID
    }
}

public struct NoteAttachment: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, file }
    public var id: UUID
    public var name: String
    public var relativePath: String
    public var kind: Kind
    public var byteCount: Int
    public init(id: UUID = UUID(), name: String, relativePath: String, kind: Kind, byteCount: Int) {
        self.id = id; self.name = name; self.relativePath = relativePath; self.kind = kind; self.byteCount = byteCount
    }
}

public struct NoteDocument: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var blocks: [NoteBlock]
    public var attachments: [NoteAttachment]
    public var paper: NotePaper
    public var editorPaper: NotePaper?
    public var pinned: Bool
    public var onLine: Bool
    public var draft: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var wasOnLine: Bool
    public init(id: UUID = UUID(), title: String = "", blocks: [NoteBlock] = [NoteBlock()], attachments: [NoteAttachment] = [], paper: NotePaper = .blue, editorPaper: NotePaper? = nil, pinned: Bool = false, onLine: Bool = false, draft: Bool = true, createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil, wasOnLine: Bool = false) {
        self.id = id; self.title = title; self.blocks = blocks; self.attachments = attachments
        self.paper = paper; self.editorPaper = editorPaper; self.pinned = pinned; self.onLine = onLine; self.draft = draft
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt; self.wasOnLine = wasOnLine
    }
    public var effectiveEditorPaper: NotePaper { editorPaper ?? paper }
    public var displayTitle: String {
        let explicitTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return explicitTitle.isEmpty ? "未命名闪念" : explicitTitle
    }
    public var plainText: String { blocks.map(\.text).joined(separator: "\n") }
}
