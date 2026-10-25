import AppKit
import SwiftUI

@MainActor enum NotesEditorFormatMenu {
    static func make(_ session: NotesEditorSession) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let view = session.textView as? NotesContinuousTextView
        let editable = view?.hasMarkedText() != true
        for (title,key,symbol,format) in [("粗体","b","bold",NotesTextFormat.bold),("斜体","i","italic",.italic),("下划线","u","underline",.underline)] {
            let item = ClosureMenuItem(title,key:key) { session.format(format) }.notesSymbol(symbol)
            item.state = view?.isSelected(format) == true ? .on : .off; item.isEnabled = editable
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let heading = NSMenu(title:"段落样式")
        for (level,title) in [(0,"正文"),(1,"标题"),(2,"小标题")] {
            let item = ClosureMenuItem(title) { view?.setHeading(level); view?.window?.makeFirstResponder(view) }
            item.state = view?.selectionHeading == level ? .on : .off; item.isEnabled = editable
            heading.addItem(item)
        }
        let paragraph = NSMenuItem(title:"段落样式",action:nil,keyEquivalent:"").notesSymbol("text.alignleft")
        paragraph.notesDetail = view?.selectionHeading.map { ["正文","标题","小标题"][min(2,max(0,$0))] } ?? "混合样式"
        paragraph.submenu = heading; menu.addItem(paragraph)
        let sizes = NSMenu(title:"文字字号")
        let values: [CGFloat?] = [nil,12,14,16,18,24]
        func sizeLabel(_ value:CGFloat) -> String { value == value.rounded() ? String(Int(value)) : String(format:"%.1f",Double(value)) }
        let defaultSize: CGFloat = NotesContinuousDocument.bodySize * (view?.selectionHeading == 1 ? 1.65 : view?.selectionHeading == 2 ? 1.28 : 1)
        let followsParagraph = view?.selectionSize.map { abs($0 - defaultSize) < 0.02 } == true
        for size in values {
            let item = ClosureMenuItem(size.map(sizeLabel) ?? (view?.selectionHeading == 0 ? "默认 · 15" : "跟随段落样式")) { view?.setTextSize(size); view?.window?.makeFirstResponder(view) }
            item.state = size == nil ? (followsParagraph ? .on : .off) : (!followsParagraph && view?.selectionSize == size ? .on : .off)
            item.isEnabled = editable; sizes.addItem(item)
        }
        let font = NSMenuItem(title:"文字字号",action:nil,keyEquivalent:"").notesSymbol("textformat.size")
        font.notesDetail = followsParagraph ? (view?.selectionHeading == 0 ? "15（默认）" : "跟随段落") : view?.selectionSize.map(sizeLabel) ?? "混合字号"
        font.submenu = sizes; menu.addItem(font)
        let bullets = ClosureMenuItem("项目列表") { session.format(.bullets) }.notesSymbol("list.bullet")
        bullets.state = view?.isSelected(.bullets) == true ? .on : .off; bullets.isEnabled = editable; menu.addItem(bullets)
        menu.addItem(.separator())
        let paste = NSMenu(title:"粘贴方式"), current = UserDefaults.standard.string(forKey:"notesPasteMode") ?? "match"
        for (value,title) in [("match","匹配闪念样式"),("preserve","保留来源格式")] {
            let item = ClosureMenuItem(title) { UserDefaults.standard.set(value,forKey:"notesPasteMode"); view?.preservePastedFormatting = value == "preserve" }
            item.state = current == value ? .on : .off; paste.addItem(item)
        }
        let pasteItem = NSMenuItem(title:"粘贴方式",action:nil,keyEquivalent:"").notesSymbol("doc.on.clipboard")
        pasteItem.notesDetail = current == "match" ? "匹配样式" : "保留格式"; pasteItem.submenu = paste; menu.addItem(pasteItem)
        return menu
    }
    static func displayMenu(_ current:Double, choose:@escaping(Double)->Void) -> NSMenu {
        let menu = NSMenu()
        for value in [0.75,1.0,1.25,1.5] {
            let item = ClosureMenuItem("\(Int((value * 100).rounded()))%") { choose(value) }
            item.state = abs(current - value) < 0.001 ? .on : .off; menu.addItem(item)
        }
        return menu
    }
}
