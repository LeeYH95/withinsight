import AppKit
import NotesCore

extension NSAttributedString.Key {
    static let notesListLevel = NSAttributedString.Key("shipian.listLevel")
    static let notesListNumber = NSAttributedString.Key("shipian.listNumber")
    static let notesListStart = NSAttributedString.Key("shipian.listStart")
    static let notesListStartLevel = NSAttributedString.Key("shipian.listStartLevel")
}

/// Lists remain ordinary NoteBlocks. Markdown carries their structure across
/// saves; the attributed marker is presentation only and never part of the body.
@MainActor enum NotesListEditing {
    struct Descriptor {
        var kind: String
        var level: Int = 0
        var number: Int = 1
    }
    static func isList(_ kind: String?) -> Bool { ["ordered", "bullet", "checklist"].contains(kind ?? "") }
    static func descriptor(_ block: NoteBlock) -> Descriptor? {
        guard block.kind == .paragraph || block.kind == .checklist else { return nil }
        let markdown = block.markdown ?? ""
        let indentation = markdown.prefix { $0 == " " || $0 == "\t" }
        let level = indentation.contains("\t") || indentation.count >= 2 ? 1 : 0
        let source = String(markdown.dropFirst(indentation.count))
        if block.kind == .checklist {
            let taskPrefix = source.hasPrefix("- [ ] ") || source.hasPrefix("- [x] ") || source.hasPrefix("- [X] ")
            return Descriptor(kind: "checklist", level: taskPrefix ? level : 0)
        }
        if source.hasPrefix("- ") || block.text.hasPrefix("• ") { return Descriptor(kind: "bullet", level: level) }
        // Historical paragraphs often store their literal text as Markdown.
        // Only the added Markdown prefix denotes our structured ordered items.
        if markdown != block.text, let prefix = orderedPrefix(source) {
            let bodyStartsWithMarker = orderedPrefix(block.text)
            let markdownBody = String(source.dropFirst(prefix.length))
            if bodyStartsWithMarker?.number == prefix.number, orderedPrefix(markdownBody) == nil { return nil }
            return Descriptor(kind: "ordered", level: level, number: prefix.number)
        }
        return nil
    }
    static func orderedPrefix(_ text: String) -> (number: Int, length: Int)? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits), number > 0, number < Int.max,
              text.dropFirst(digits.count).hasPrefix(". ") || text.dropFirst(digits.count).hasPrefix(".\t") else { return nil }
        return (number, digits.count + 2)
    }
    static func shortcut(_ text: String) -> Descriptor? {
        if ["- ", "* ", "+ "].contains(text) { return Descriptor(kind: "bullet") }
        if let prefix = orderedPrefix(text), prefix.length == text.utf16.count { return Descriptor(kind: "ordered", number: prefix.number) }
        return nil
    }
    static func markdownPrefix(_ list: Descriptor, checked: Bool = false) -> String {
        let indent = list.level > 0 ? "  " : ""
        if list.kind == "ordered" { return indent + "\(list.number). " }
        if list.kind == "checklist" { return indent + "- [\(checked ? "x" : " ")] " }
        return indent + "- "
    }
    static func marker(kind: String, number: Int = 1, checked: Bool = false, font: NSFont) -> NSAttributedString {
        if kind == "checklist" { return NotesContinuousDocument.taskMarker(checked: checked, size: font.pointSize, baselineFont: font) }
        return NSAttributedString(string: kind == "ordered" ? "\(number).\t" : "•\t", attributes: [.font: font, .notesMarker: true])
    }
    static func markerRange(in value: NSAttributedString, paragraph: NSRange) -> NSRange {
        guard paragraph.location < value.length, value.attribute(.notesMarker, at: paragraph.location, effectiveRange: nil) as? Bool == true else { return NSRange(location: paragraph.location, length: 0) }
        var end = paragraph.location
        while end < NSMaxRange(paragraph), value.attribute(.notesMarker, at: end, effectiveRange: nil) as? Bool == true { end += 1 }
        return NSRange(location: paragraph.location, length: end - paragraph.location)
    }
    static func map(_ selection: NSRange, replacing range: NSRange, length: Int, moveStart: Bool = false) -> NSRange {
        func position(_ position: Int) -> Int {
            if position > range.location || moveStart && position == range.location {
                if position >= NSMaxRange(range) { return position + length - range.length }
                return range.location + length
            }
            return position
        }
        let start = position(selection.location), end = position(NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }

    /// One pass handles pasted fragments, split/merged paragraphs and digit-width
    /// changes. Selection is mapped through each replacement before publishing.
    @discardableResult static func normalize(_ value: NSMutableAttributedString, selection: NSRange) -> NSRange {
        var selection = selection, cursor = 0
        var kinds: [String?] = [nil, nil], numbers = [0, 0], starts = [0, 0]
        var text = value.string as NSString
        while cursor < text.length {
            var paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            var attrs = value.attributes(at: cursor, effectiveRange: nil)
            let kind = attrs[.notesKind] as? String ?? "paragraph"
            let list = isList(kind)
            let level = min(1, max(0, attrs[.notesListLevel] as? Int ?? 0))
            var number = 1
            if list {
                if level == 0 { kinds[1] = nil; numbers[1] = 0; starts[1] = 0 }
                if kind == "ordered" {
                    let initial = min(Int.max - 1, max(1, attrs[.notesListNumber] as? Int ?? 1))
                    let remembered = (attrs[.notesListStartLevel] as? Int) == level ? attrs[.notesListStart] as? Int : nil
                    let seed = min(Int.max - 1, max(1, remembered ?? initial))
                    if kinds[level] != kind { starts[level] = seed }
                    number = kinds[level] == kind ? min(Int.max - 1, numbers[level] + 1) : seed
                    numbers[level] = number
                } else { numbers[level] = 0; starts[level] = 0 }
                kinds[level] = kind
                attrs[.notesListLevel] = level
                attrs[.notesListNumber] = number
            } else { kinds = [nil, nil]; numbers = [0, 0]; starts = [0, 0] }
            let leading = markerRange(in: value, paragraph: paragraph)
            var obsolete: [NSRange] = []
            value.enumerateAttribute(.notesMarker, in: paragraph) { marked, run, _ in
                if marked as? Bool == true, !list || run.location >= NSMaxRange(leading) { obsolete.append(run) }
            }
            // A removed newline may leave the following item's synthetic marker
            // inside the merged body. Remove that marker without touching text.
            for range in obsolete.reversed() {
                value.deleteCharacters(in: range)
                selection = map(selection, replacing: range, length: 0)
                paragraph.length -= range.length
            }
            if !obsolete.isEmpty { text = value.string as NSString }
            if list {
                let replacement = markerRange(in: value, paragraph: paragraph)
                let markerText = kind == "ordered" ? "\(number).\t" : kind == "checklist" ? "\u{FFFC}\t" : "•\t"
                if text.substring(with: replacement) != markerText {
                    var clean = attrs
                    for key in [.attachment, .notesMarker, .link, .toolTip, .notesPendingLink] as [NSAttributedString.Key] { clean.removeValue(forKey: key) }
                    let font = clean[.font] as? NSFont ?? NSFont.systemFont(ofSize: NotesContinuousDocument.bodySize)
                    let marker = NSMutableAttributedString(attributedString: NotesListEditing.marker(kind: kind, number: number, checked: attrs[.notesChecked] as? Bool ?? false, font: font))
                    marker.addAttributes(clean, range: NSRange(location: 0, length: marker.length))
                    value.replaceCharacters(in: replacement, with: marker)
                    selection = map(selection, replacing: replacement, length: marker.length, moveStart: replacement.length == 0)
                    paragraph.length += marker.length - replacement.length
                    text = value.string as NSString
                }
                value.updateNotesAttribute(.notesKind, value: kind as NSString, range: paragraph)
                value.updateNotesAttribute(.notesListLevel, value: NSNumber(value: level), range: paragraph)
                value.updateNotesAttribute(.notesListNumber, value: NSNumber(value: number), range: paragraph)
            }
            if kind == "ordered" {
                value.updateNotesAttribute(.notesListStart, value: NSNumber(value: starts[level]), range: paragraph)
                value.updateNotesAttribute(.notesListStartLevel, value: NSNumber(value: level), range: paragraph)
            } else {
                value.updateNotesAttribute(.notesListStart, value: nil, range: paragraph)
                value.updateNotesAttribute(.notesListStartLevel, value: nil, range: paragraph)
            }
            cursor = NSMaxRange(paragraph)
        }
        return selection
    }
}
