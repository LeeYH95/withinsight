import SwiftUI

/// Shared movement of everything clipped to the rope. These are the original
/// PeggedView timings and spring constants; the paper controls use them too.
@MainActor final class HangingSwing: ObservableObject {
    @Published private(set) var angle: Double = 0
    @Published private(set) var arrived = false

    func arrive(alreadyInPlace: Bool = false) {
        guard !HangingMotion.reduced else { arrived = true; angle = 0; return }
        if alreadyInPlace { arrived = true; return }
        angle = 16
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { angle = 0 }
    }

    func breeze() {
        guard !HangingMotion.reduced else { return }
        let delay = Double.random(in: 0...0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let degrees = Double.random(in: 1.6...3.4)
            withAnimation(.easeOut(duration: 0.25)) { self.angle = degrees }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: 0.65, dampingFraction: 0.75)) { self.angle = 0 }
            }
        }
    }

    func nudge(_ degrees: Double) {
        guard !HangingMotion.reduced else { angle = 0; return }
        withAnimation(.easeOut(duration: 0.3)) { angle = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { self.angle = 0 }
        }
    }
}
