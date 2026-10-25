import AppKit

/// Finder and Dock use the compiled icon catalog, with ICNS for older systems.
/// Settings keeps the original artwork; runtime icons retain catalog masking.
@MainActor enum NotesAppIcon {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "拾片"
    }
    static func resourceName(theme: String, systemDark: Bool) -> String {
        let dark = theme == "dark" || (theme != "light" && theme != "dark" && systemDark)
        return dark ? "ShipianIconDark" : "ShipianIconLight"
    }
    static func resolve(theme: String, systemDark: Bool, load: (String) -> NSImage?) -> NSImage? {
        let name = resourceName(theme: theme, systemDark: systemDark)
        return load(name) ?? (name == "ShipianIconDark" ? load("ShipianIconLight") : nil)
    }
    private static var cached: [String: NSImage] = [:]
    static var isDark: Bool {
        resourceName(theme: UserDefaults.standard.string(forKey: "notesTheme") ?? "system",
                     systemDark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == "ShipianIconDark"
    }
    static func image() -> NSImage? {
        resolve(theme: UserDefaults.standard.string(forKey: "notesTheme") ?? "system",
                systemDark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) { name in
            if let image = cached[name] { return image }
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let image = NSImage(contentsOf: url) else { return nil }
            cached[name] = image
            return image
        }
    }
    static func refresh() {
        let name = isDark ? "ShipianDark" : "ShipianLight"
        if let image = cached[name] { NSApp.applicationIconImage = image; return }
        // Loading a loose PNG here bypasses the catalog's rounded mask and
        // produces a different Dock tile from the installed app icon.
        guard let image = NSImage(named: NSImage.Name(name)) else {
            NSApp.applicationIconImage = nil
            return
        }
        cached[name] = image
        NSApp.applicationIconImage = image
    }
}
