import CoreMotion
import SwiftUI
import MoReadCore

@MainActor final class ReviewTilt: ObservableObject {
    @Published private(set) var value = ReviewTiltState()
    private let manager = CMMotionManager()
    func setEnabled(_ enabled: Bool) {
        guard enabled else { stop(); return }
        guard !manager.isDeviceMotionActive, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self, self.manager.isDeviceMotionActive else { return }
            guard error == nil, let motion else { self.stop(); return }
            self.value.update(gravityX: motion.gravity.x * 9.81, gravityY: motion.gravity.y * 9.81)
        }
    }
    func stop() { manager.stopDeviceMotionUpdates(); value = ReviewTiltState() }
    deinit { manager.stopDeviceMotionUpdates() }
}
