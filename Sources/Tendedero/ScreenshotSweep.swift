import AppKit
import Combine
import QuartzCore

struct ScreenshotSweepPlan {
    struct Target { let id: UUID; let x: CGFloat }
    struct Frame {
        let tip: CGPoint
        let angle: Double
        let opacity: Double
        let contacts: [UUID]
        let finished: Bool
    }
    let width: CGFloat
    let targets: [Target]
    static let duration: TimeInterval = 1.84

    init(width: CGFloat, targets: [Target]) {
        self.width = max(1, width)
        self.targets = targets.filter { $0.x.isFinite }.sorted { $0.x < $1.x }
    }

    func frame(at time: TimeInterval) -> Frame {
        let t = max(0, time)
        let start = max(4, (targets.first?.x ?? 50) - 50)
        let end = max(start + 1, (targets.last?.x ?? start) + 24)
        let p = min(1, max(0, (t - 0.16) / 1.08))
        let eased = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
        let x = start + (end - start) * eased
        let proximity = targets.map { max(0, 1 - abs(x - $0.x) / 22) }.max() ?? 0
        let y = Layout.ropeY(x: x, width: width) + 3 - 3 * sin(proximity * .pi / 2)
        let opacity = min(min(1, t / 0.16), max(0, 1 - (t - 1.24) / 0.18))
        return Frame(tip: CGPoint(x: x, y: y), angle: -2 * Double(proximity), opacity: opacity,
                     contacts: t >= 0.16 ? targets.filter { x >= $0.x - 1 }.map(\.id) : [],
                     finished: targets.isEmpty || t >= Self.duration)
    }
}

/// Only the small overlay observes frame ticks; the entire rope does not redraw.
@MainActor final class ScreenshotSweepMotion: ObservableObject {
    @Published private(set) var pose: ScreenshotSweepPlan.Frame?
    var width: CGFloat? { plan?.width }
    private var plan: ScreenshotSweepPlan?
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    private var contacts: Set<UUID> = []
    private var onContact: ((UUID) -> Void)?
    private var onFinish: (() -> Void)?
    private var generation: UInt = 0

    func start(_ plan: ScreenshotSweepPlan, reduced: Bool = false, automatic: Bool = true,
               onContact: @escaping (UUID) -> Void, onFinish: @escaping () -> Void) {
        complete()
        guard !reduced, !plan.targets.isEmpty else { onFinish(); return }
        generation &+= 1
        self.plan = plan; self.onContact = onContact; self.onFinish = onFinish
        contacts = []; started = CACurrentMediaTime()
        advance(to: 0)
        guard automatic else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if HangingMotion.reduced { self.complete() }
                else { self.advance(to: CACurrentMediaTime() - self.started) }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func advance(to time: TimeInterval) {
        guard let plan else { return }
        let run = generation
        let frame = plan.frame(at: time)
        pose = frame
        for id in frame.contacts where contacts.insert(id).inserted {
            onContact?(id)
            guard run == generation, self.plan != nil else { return }
        }
        if frame.finished { complete() }
    }

    /// The owner commits pending off-screen removals in its completion callback.
    func complete() {
        timer?.invalidate(); timer = nil
        plan = nil; pose = nil; onContact = nil
        let finish = onFinish; onFinish = nil
        finish?()
    }
}
