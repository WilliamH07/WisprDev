import Foundation

struct BenchmarkTests {
    static func run() {
        let wav = SyntheticSpeechWAV.make(seconds: 1, sampleRate: 16_000)
        TestSupport.expectEqual(wav.count, 44 + 16_000 * 2)
        TestSupport.expectEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        TestSupport.expectEqual(String(decoding: wav.subdata(in: 8..<12), as: UTF8.self), "WAVE")
        TestSupport.expect(BenchmarkMath.median([]) == nil, "median of nothing is nil")
        TestSupport.expectApproximatelyEqual(BenchmarkMath.median([3, 1, 2]) ?? -1, 2)
        TestSupport.expectApproximatelyEqual(BenchmarkMath.median([1, 2, 3, 10]) ?? -1, 2.5)

        UserDefaults.standard.removeObject(forKey: TranscriptFastPath.maxWordsStorageKey)
        TestSupport.expectEqual(TranscriptFastPath.configuredMaxWords, TranscriptFastPath.defaultMaxWords)
        UserDefaults.standard.set(999, forKey: TranscriptFastPath.maxWordsStorageKey)
        TestSupport.expectEqual(TranscriptFastPath.configuredMaxWords, TranscriptFastPath.maxWordsRange.upperBound)
        UserDefaults.standard.removeObject(forKey: TranscriptFastPath.maxWordsStorageKey)
    }
}
