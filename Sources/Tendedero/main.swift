import AppKit

MainActor.assumeIsolated {
    LaunchTrace.mark("process-start")
    let app = NSApplication.shared
    LaunchTrace.mark("appkit-ready")
    let delegate = AppDelegate()
    LaunchTrace.mark("app-delegate-ready")
    app.delegate = delegate
    app.setActivationPolicy(LaunchOptions.demo ? .accessory : .regular)
    LaunchTrace.mark("entering-run-loop")
    withExtendedLifetime(delegate) { app.run() }
}
