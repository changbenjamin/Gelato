@preconcurrency import AVFoundation
import Foundation

struct CapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let capturedAt: Date
}

enum CaptureClock {
    static func date(forHostTime hostTime: UInt64) -> Date {
        let hostSeconds = AVAudioTime.seconds(forHostTime: hostTime)
        let uptime = ProcessInfo.processInfo.systemUptime
        return Date().addingTimeInterval(hostSeconds - uptime)
    }
}
