import Foundation

struct SessionAudioTiming: Codable, Sendable {
    let micFirstBufferAt: Date?
    let systemFirstBufferAt: Date?
    let micChunks: [SessionAudioChunk]?
    let systemChunks: [SessionAudioChunk]?
    private static let chunkDiscontinuityThresholdSeconds: TimeInterval = 0.010
    private static let sampleRateMismatchToleranceSeconds: TimeInterval = 0.015
    private static let suspectedSampleRateMismatchRatio: Double = 0.3

    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(SessionAudioDateCoding.encode(date))
        }
        return encoder
    }

    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let stringValue = try? container.decode(String.self),
               let date = SessionAudioDateCoding.decode(stringValue) {
                return date
            }

            if let numericValue = try? container.decode(Double.self) {
                return SessionAudioDateCoding.decode(numericValue)
            }

            if let numericValue = try? container.decode(Int64.self) {
                return SessionAudioDateCoding.decode(Double(numericValue))
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported date value"
            )
        }
        return decoder
    }

    static func shouldUseChunkTiming(
        _ chunks: [SessionAudioChunk]?,
        sampleRate: Double
    ) -> Bool {
        let validChunks = self.validChunks(chunks)
        guard validChunks.count > 1, sampleRate > 0 else { return false }

        var discontinuityCount = 0
        var sampleRateMismatchLikeCount = 0

        for index in 1..<validChunks.count {
            let previous = validChunks[index - 1]
            let current = validChunks[index]
            let expectedDelta = Double(previous.frameCount) / sampleRate
            let measuredDelta = current.capturedAt.timeIntervalSince(previous.capturedAt)
            let drift = measuredDelta - expectedDelta

            if abs(drift) >= chunkDiscontinuityThresholdSeconds {
                discontinuityCount += 1

                let mismatchTolerance = max(
                    sampleRateMismatchToleranceSeconds,
                    expectedDelta * 0.25
                )
                if drift > 0,
                   abs(drift - expectedDelta) <= mismatchTolerance {
                    sampleRateMismatchLikeCount += 1
                }
            }
        }

        guard discontinuityCount > 0 else { return false }

        let transitionCount = validChunks.count - 1
        let mismatchRatio = Double(sampleRateMismatchLikeCount) / Double(transitionCount)
        if mismatchRatio >= suspectedSampleRateMismatchRatio {
            diagLog(
                "[AUDIO] ignoring chunk timing due to suspected sample-rate mismatch " +
                "sampleRate=\(sampleRate) discontinuities=\(discontinuityCount)/\(transitionCount)"
            )
            return false
        }

        return true
    }

    static func validChunks(_ chunks: [SessionAudioChunk]?) -> [SessionAudioChunk] {
        (chunks ?? []).filter { $0.frameCount > 0 }
    }

    static func offsetSeconds(
        from streamStart: Date?,
        relativeTo origin: Date?,
        trustRoundedOffsets: Bool
    ) -> TimeInterval {
        guard let streamStart, let origin else { return 0 }
        let offset = max(0, streamStart.timeIntervalSince(origin))

        if !trustRoundedOffsets,
           streamStart.isNearlyWholeSecond,
           origin.isNearlyWholeSecond,
           offset < 1.5 {
            return 0
        }

        return offset
    }
}

struct SessionAudioChunk: Codable, Sendable {
    let capturedAt: Date
    let frameCount: Int
}

private enum SessionAudioDateCoding {
    static func fractionalISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    static func basicISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    static func encode(_ date: Date) -> Double {
        date.timeIntervalSince1970
    }

    static func decode(_ value: String) -> Date? {
        fractionalISO8601Formatter().date(from: value)
            ?? basicISO8601Formatter().date(from: value)
    }

    static func decode(_ value: Double) -> Date {
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}

private extension Date {
    var isNearlyWholeSecond: Bool {
        abs(timeIntervalSince1970 - timeIntervalSince1970.rounded()) < 0.000_5
    }
}
