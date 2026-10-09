import Foundation

/// Presentation state only. System PiP controls must never own microphone state.
public struct CaptionWindowPlayback: Sendable {
    public private(set) var paused = false
    public private(set) var automaticStartAllowed = true
    public init() {}
    public mutating func setPlaying(_ playing: Bool) { paused = !playing }
    public mutating func openManually() { paused = false; automaticStartAllowed = true }
    public mutating func close(userInitiated: Bool) {
        paused = false
        if userInitiated { automaticStartAllowed = false }
    }
    public mutating func reset() { self = Self() }
    public func caption(recording: Bool) -> String {
        paused ? "字幕已暂停 · \(recording ? "录音中" : "录音已暂停")" : recording ? "录音中" : "已暂停"
    }
}
