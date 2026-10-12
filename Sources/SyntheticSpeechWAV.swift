import Foundation

/// Builds a small synthetic WAV (amplitude-modulated tone) used only to time
/// transcription engines. It contains no recorded or user audio.
enum SyntheticSpeechWAV {
    static func make(seconds: Double = 4, sampleRate: Int = 16_000) -> Data {
        let sampleCount = max(1, Int(seconds * Double(sampleRate)))
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let t = Double(index) / Double(sampleRate)
            let envelope = 0.5 + 0.5 * sin(2 * Double.pi * 3 * t)
            let value = 0.3 * envelope * sin(2 * Double.pi * 220 * t)
            samples.append(Int16(max(-1, min(1, value)) * Double(Int16.max)))
        }

        let dataSize = sampleCount * 2
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)                       // PCM
        append16(1)                       // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))  // byte rate
        append16(2)                       // block align
        append16(16)                      // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        for sample in samples {
            append16(UInt16(bitPattern: sample))
        }
        return data
    }
}

enum BenchmarkMath {
    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
