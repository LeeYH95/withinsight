import AppKit
import Darwin
import NotesCore

/// Only spawned harness children and UUID-named fixture directories are killed.
@MainActor enum DurabilityProbe {
    static func child(_ arguments: [String]) throws {
        let phase = arguments[0], root = URL(fileURLWithPath: arguments[1])
        let store = try NotesStore(directory: root.appendingPathComponent("store"))
        if phase == "race" {
            let worker = arguments[2]
            var note = store.documents[0]
            try Data().write(to: root.appendingPathComponent("ready-" + worker))
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("start").path) { usleep(1_000) }
            note.title = worker
            let result: String
            do { try store.update(note); result = "saved" }
            catch let error as NotesStoreError where error == .storeChanged || error == .storeBusy { result = "conflict" }
            try Data(result.utf8).write(to: root.appendingPathComponent("result-" + worker))
            return
        }
        var note = try store.create()
        note.title = "已保存的原始标题"
        note.blocks = [NoteBlock(text: "中英文正文 original", richText: Data("opaque-rtf-fixture".utf8)), NoteBlock(kind: .checklist, text: "待办内容", isChecked: true)]
        note.editorPaper = .rose; note.pinned = true
        try store.update(note)
        let source = root.appendingPathComponent("original.txt")
        try Data("attachment bytes must survive".utf8).write(to: source)
        _ = try store.importAttachment(from: source, to: note.id)
        let session = NotesEditorSession(note: store.document(id: note.id)!, store: store)
        session.undoManager.groupsByEvent = false
        func group(_ operation: () throws -> Void) rethrows {
            session.undoManager.beginUndoGrouping()
            defer { session.undoManager.endUndoGrouping() }
            try operation()
        }
        if phase == "saved" {
            try group { session.changeTitle("强退前已确认保存"); try session.commit() }
        }
        if phase == "pending" {
            group { session.changeTitle("最后一次输入必须在强退后恢复") }
        }
        if phase == "pending-body" {
            let text = "刚输入的中文正文，尚未等待自动保存。 English 123。"
            let attributed = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 19)])
            attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 19), range: (text as NSString).range(of: "中文正文"))
            let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            var block = session.note.blocks[0]
            block.text = text; block.richText = rtf; block.markdown = "刚输入的**中文正文**，尚未等待自动保存。 English 123。"
            group { session.updateText(block) }
        }
        if phase == "pending-continuous" {
            let view = NotesContinuousTextView(frame:NSRect(x:0,y:0,width:480,height:300),textContainer:nil)
            view.session = session; session.textView = view
            view.loadDocument(session.note)
            view.setSelectedRange(NSRange(location:0,length:0))
            view.insertText("强退前连续正文：",replacementRange:view.selectedRange())
            view.setSelectedRange(NSRange(location:0,length:4)); view.setTextSize(32)
            let blocks = try NotesContinuousDocument.blocks(from:view.attributedString())
            group { session.updateBlocks(blocks) }
        }
        if phase == "pending-checklist" {
            group { session.toggle(session.note.blocks[1].id) }
        }
        if phase == "pending-undo-attachment" {
            let attachment = session.note.attachments[0]
            try group { session.removeAttachment(attachment); try session.commit() }
            guard !FileManager.default.fileExists(atPath: try store.url(for: attachment).path) else {
                throw NSError(domain: "DurabilityProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Removal must collect owned attachment before the undo crash probe"])
            }
            session.undo()
        }
        let expected = phase.hasPrefix("pending") ? session.note : store.document(id: note.id)!
        try JSONEncoder().encode(expected).write(to: root.appendingPathComponent("expected.json"))
        if phase == "writing" {
            var generation = 0
            while true {
                var value = session.note.blocks[0]
                value.text = String(repeating: "持续写入中文内容", count: 8_000) + "-\(generation)"
                try group { session.updateText(value); try session.commit() }
                if generation == 0 { try Data().write(to: root.appendingPathComponent("ready")) }
                generation += 1
            }
        }
        try Data().write(to: root.appendingPathComponent("ready"))
        // Do not run the autosave timer: this represents a kill before its deadline.
        while true { pause() }
    }

    static func run(root: URL, check: (Bool, String) -> Void) throws {
        func launch(_ phase: String, _ location: URL, worker: String? = nil) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--durability-child", phase, location.path] + (worker.map { [$0] } ?? [])
            try process.run(); return process
        }
        func waitFor(_ marker: URL, process: Process) throws {
            let deadline = Date().addingTimeInterval(12)
            while !FileManager.default.fileExists(atPath: marker.path), process.isRunning, Date() < deadline { usleep(5_000) }
            guard FileManager.default.fileExists(atPath: marker.path) else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
                throw NSError(domain: "DurabilityProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture child did not become ready: " + marker.path])
            }
        }
        var failedChecks: [String] = []
        func expect(_ condition: Bool, _ name: String) {
            if condition { check(true, name) }
            else { failedChecks.append(name); print("FAIL: " + name) }
        }
        func sameContent(_ first: NoteDocument, _ second: NoteDocument) -> Bool {
            var normalized = first
            normalized.updatedAt = second.updatedAt
            return normalized == second
        }
        for phase in ["saved", "pending", "pending-body", "pending-continuous", "pending-checklist", "pending-undo-attachment", "writing", "writing", "writing"] {
            let location = root.appendingPathComponent("kill-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
            let child = try launch(phase, location)
            try waitFor(location.appendingPathComponent("ready"), process: child)
            if phase == "writing" { usleep(30_000) }
            kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
            let store = try NotesStore(directory: location.appendingPathComponent("store"))
            let expected = try JSONDecoder().decode(NoteDocument.self, from: Data(contentsOf: location.appendingPathComponent("expected.json")))
            guard let actual = store.document(id: expected.id) else {
                throw NSError(domain: "DurabilityProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Crash restart must preserve the note identity"])
            }
            expect(actual.blocks[1] == expected.blocks[1] && actual.editorPaper == .rose && actual.pinned, "SIGKILL preserves final checklist, appearance and identity (\(phase))")
            let attachmentBytes = try actual.attachments.map { try Data(contentsOf: store.url(for: $0)) }
            expect(attachmentBytes == [Data("attachment bytes must survive".utf8)], "SIGKILL preserves final owned attachment bytes (\(phase))")
            if phase == "writing" {
                expect(actual.blocks[0].text.hasPrefix("持续写入中文内容"), "kill during repeated atomic writes reopens a complete snapshot")
            } else {
                expect(sameContent(actual, expected), "process restart recovers the final editor content before autosave (\(phase))")
            }
            if phase == "pending-body" {
                let rtf = actual.blocks[0].richText ?? Data()
                let decoded = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                expect(decoded?.string == expected.blocks[0].text, "recovered pending Chinese body has readable RTF with matching text")
                if let decoded, let range = decoded.string.range(of: "中文正文") {
                    let font = decoded.attribute(.font, at: NSRange(range, in: decoded.string).location, effectiveRange: nil) as? NSFont
                    expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "recovered pending RTF retains inline bold formatting")
                } else { expect(false, "recovered pending RTF retains inline bold formatting") }
            }
            let secondOpen = try NotesStore(directory: store.directory)
            expect(secondOpen.documents.count == store.documents.count && secondOpen.document(id: actual.id).map { sameContent($0, actual) } == true, "a second restart does not duplicate or change recovered content (\(phase))")
            if let reopened = secondOpen.document(id: actual.id) {
                let reopenedBytes = try reopened.attachments.map { try Data(contentsOf: secondOpen.url(for: $0)) }
                expect(reopenedBytes == attachmentBytes, "a second restart retains recovered attachment bytes (\(phase))")
            }
            expect(try Data(contentsOf: location.appendingPathComponent("original.txt")) == Data("attachment bytes must survive".utf8), "crash recovery never modifies the external attachment source (\(phase))")
        }
        let race = root.appendingPathComponent("writer-race")
        let seed = try NotesStore(directory: race.appendingPathComponent("store"))
        _ = try seed.create()
        let first = try launch("race", race, worker: "one"), second = try launch("race", race, worker: "two")
        try waitFor(race.appendingPathComponent("ready-one"), process: first)
        try waitFor(race.appendingPathComponent("ready-two"), process: second)
        try Data().write(to: race.appendingPathComponent("start"))
        try waitFor(race.appendingPathComponent("result-one"), process: first)
        try waitFor(race.appendingPathComponent("result-two"), process: second)
        first.waitUntilExit(); second.waitUntilExit()
        let results = try ["one", "two"].map { try String(contentsOf: race.appendingPathComponent("result-" + $0), encoding: .utf8) }.sorted()
        check(results == ["conflict", "saved"], "two simultaneous processes cannot silently overwrite one another")
        let reopened = try NotesStore(directory: seed.directory)
        check(reopened.documents.count == 1 && ["one", "two"].contains(reopened.documents[0].title), "multi-process conflict leaves a valid saved document")
        check(failedChecks.isEmpty, "all pending editor SIGKILL recovery checks pass")
    }
}
