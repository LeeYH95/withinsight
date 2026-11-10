import Foundation

enum RopeGroupKind: String, CaseIterable {
    case images, notes

    private static let imagesID = UUID()
    private static let notesID = UUID()

    var id: UUID { self == .images ? Self.imagesID : Self.notesID }
    var label: String { self == .images ? "图片" : "闪念" }
    var unit: String { self == .images ? "张" : "条" }
    var symbol: String { self == .images ? "photo.on.rectangle" : "doc.text" }
    var defaultsKey: String { "ropeFolding." + rawValue }
}

struct RopeFoldRule: Equatable {
    var enabled = true
    var threshold = 4

    init(enabled: Bool = true, threshold: Int = 4) {
        self.enabled = enabled
        self.threshold = threshold > 0 ? threshold : 4
    }

    init(kind: RopeGroupKind, defaults: UserDefaults) {
        let key = kind.defaultsKey
        self.init(enabled: defaults.object(forKey: key + ".enabled") as? Bool ?? true,
                  threshold: defaults.object(forKey: key + ".threshold") as? Int ?? 4)
    }

    func save(kind: RopeGroupKind, defaults: UserDefaults) {
        let key = kind.defaultsKey
        defaults.set(enabled, forKey: key + ".enabled")
        defaults.set(threshold, forKey: key + ".threshold")
    }

    func groups(_ count: Int) -> Bool { enabled && count > threshold }
}
