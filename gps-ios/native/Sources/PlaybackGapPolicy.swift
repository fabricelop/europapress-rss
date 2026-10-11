import Foundation

// Keep playback conservative when location samples are missing.
enum PlaybackGapPolicy {
    static func canInterpolate(seconds: TimeInterval) -> Bool {
        seconds > 0 && seconds <= 180
    }
}
