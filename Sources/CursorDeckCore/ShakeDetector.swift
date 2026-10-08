import AppKit
import Foundation

/// Detects a rapid back-and-forth shake of the mouse pointer to discard/clear the entire active deck.
public final class ShakeDetector {
    public var isEnabled: Bool = true
    public var onShakeDetected: (() -> Void)?

    private var samples: [(x: CGFloat, t: TimeInterval)] = []
    private var cooldownUntil: TimeInterval = 0

    private let minReversals: Int = 4
    private let minTravelDistance: CGFloat = 320.0
    private let windowDuration: TimeInterval = 0.42
    private let cooldownDuration: TimeInterval = 0.80
    private let minDeltaToCount: CGFloat = 3.0

    public init() {}

    public func observe(x: CGFloat) {
        guard isEnabled else { return }

        let now = CACurrentMediaTime()
        if now < cooldownUntil { return }

        // Remove samples outside sliding window
        let cutoff = now - windowDuration
        while let oldest = samples.first, oldest.t < cutoff {
            samples.removeFirst()
        }
        samples.append((x: x, t: now))

        guard samples.count >= 6 else { return }

        var reversals = 0
        var travel: CGFloat = 0.0
        var lastDirection = 0

        for i in 1..<samples.count {
            let dx = samples[i].x - samples[i - 1].x
            if abs(dx) < minDeltaToCount { continue }
            let dir = dx > 0 ? 1 : -1
            if lastDirection != 0 && dir != lastDirection {
                reversals += 1
            }
            lastDirection = dir
            travel += abs(dx)
        }

        if reversals >= minReversals && travel >= minTravelDistance {
            cooldownUntil = now + cooldownDuration
            samples.removeAll()
            onShakeDetected?()
        }
    }

    public func reset() {
        samples.removeAll()
    }
}
