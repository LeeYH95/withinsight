import AppKit
import XCTest
@testable import Tendedero

final class ScreenshotSweepTests: XCTestCase {
    func testContactsFollowLeftToRightGeometryInsteadOfInputOrder() {
        let left = UUID(), right = UUID()
        let plan = ScreenshotSweepPlan(width: 1200, targets: [.init(id: right, x: 800), .init(id: left, x: 200)])
        XCTAssertTrue(plan.frame(at: 0).contacts.isEmpty)
        XCTAssertEqual(plan.frame(at: 0.55).contacts, [left])
        XCTAssertEqual(plan.frame(at: 1.24).contacts, [left, right])
        XCTAssertLessThan(plan.frame(at: 0.3).tip.x, plan.frame(at: 0.8).tip.x)
        XCTAssertEqual(plan.frame(at: 1.24).opacity, 1, accuracy: 0.01)
        XCTAssertTrue(plan.frame(at: 1.9).finished)
    }

    func testRodHasFiniteHorizontalPoseAndClearsAfterFallHasTimeToFinish() {
        let plan = ScreenshotSweepPlan(width: 1000, targets: [.init(id: UUID(), x: 400)])
        for t in [0.0, 0.16, 0.5, 1.0, 1.4, 1.84] {
            let frame = plan.frame(at: t)
            XCTAssertTrue(frame.tip.x.isFinite && frame.tip.y.isFinite)
            XCTAssertLessThanOrEqual(abs(frame.angle), 2.01)
            XCTAssertTrue((0...1).contains(frame.opacity))
        }
        XCTAssertFalse(plan.frame(at: 1.4).finished, "Keep slots frozen until the final falling card is gone")
        XCTAssertTrue(plan.frame(at: 1.84).finished)
    }

    @MainActor func testControllerContactsOnceAndCompletionCannotFireTwice() {
        let a = UUID(), b = UUID()
        let plan = ScreenshotSweepPlan(width: 1200, targets: [.init(id: a, x: 200), .init(id: b, x: 800)])
        let motion = ScreenshotSweepMotion()
        var contacts: [UUID] = [], completions = 0
        motion.start(plan, automatic: false, onContact: { contacts.append($0) }, onFinish: { completions += 1 })
        motion.advance(to: 0.55); motion.advance(to: 0.55); motion.advance(to: 1.24)
        XCTAssertEqual(contacts, [a, b])
        motion.advance(to: 1.84); motion.advance(to: 2)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(motion.pose)
    }

    @MainActor func testReducedMotionAndNoVisibleTargetsFinishWithoutAnimating() {
        for reduced in [false, true] {
            let motion = ScreenshotSweepMotion()
            let targets: [ScreenshotSweepPlan.Target] = reduced ? [.init(id: UUID(), x: 200)] : []
            var contacts = 0, completions = 0
            motion.start(.init(width: 1200, targets: targets), reduced: reduced, automatic: false,
                         onContact: { _ in contacts += 1 }, onFinish: { completions += 1 })
            XCTAssertEqual(contacts, 0)
            XCTAssertEqual(completions, 1)
            XCTAssertNil(motion.pose)
        }
    }

    @MainActor func testInterruptionStopsTheRodAndFinalizesOnlyOnce() {
        let motion = ScreenshotSweepMotion()
        var completions = 0
        motion.start(.init(width: 1000, targets: [.init(id: UUID(), x: 400)]), automatic: false,
                     onContact: { _ in }, onFinish: { completions += 1 })
        motion.advance(to: 0.3)
        XCTAssertNotNil(motion.pose)
        motion.complete()
        motion.advance(to: 2); motion.complete()
        XCTAssertNil(motion.pose)
        XCTAssertEqual(completions, 1)
    }
}
