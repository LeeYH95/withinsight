import Foundation

enum LaunchOptions {
    static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LineNotes" }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0" }
    static let testBuild = Bundle.main.bundleIdentifier == "local.linenotes.test"
    static let demo = ProcessInfo.processInfo.arguments.contains("--demo")
    #if DEBUG
    static let demoRope = demo && ProcessInfo.processInfo.arguments.contains("--demo-rope")
    #else
    static let demoRope = false
    #endif
    static let lineDefaults: UserDefaults = demo
        ? UserDefaults(suiteName: (Bundle.main.bundleIdentifier ?? "local.linenotes.dev") + ".demo.line")!
        : .standard
    static var directory: URL {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--data-dir"), args.indices.contains(index + 1) {
            return URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(testBuild ? (demo ? "LineNotes Test Demo" : "LineNotes Test") : (demo ? "LineNotes Demo" : "LineNotes"), isDirectory: true)
    }
}
