import AppKit

/// Opt-in launch instrumentation for local acceptance. No file is written
/// unless a report path is explicitly supplied by the test runner.
@MainActor enum LaunchTrace {
    private struct Event: Encodable, Sendable {
        let phase: String
        let seconds: TimeInterval
    }
    private struct Report: Encodable, Sendable {
        let pid: Int32
        let events: [Event]
    }
    private static let began = ProcessInfo.processInfo.systemUptime
    private static var events: [Event] = []
    private static let writer = DispatchQueue(label: "shipian.launch-trace", qos: .utility)
    private static let destination: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--startup-report"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }()
    static func mark(_ phase: String) {
        guard let destination else { return }
        events.append(Event(phase: phase, seconds: max(0, ProcessInfo.processInfo.systemUptime - began)))
        let report = Report(pid: ProcessInfo.processInfo.processIdentifier, events: events)
        // An external or protected volume can stall open(). Keep that I/O off
        // the main thread, and preserve report order even during slow writes.
        writer.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) {
                let url = URL(fileURLWithPath: destination, isDirectory: false)
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
