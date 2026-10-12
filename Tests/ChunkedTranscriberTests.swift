import Foundation

struct ChunkedTranscriberTests {
    private static let rate = 24_000

    static func run() {
        testChunkingAtPauses()
        testNoChunkForContinuousSpeech()
        testNoiseOnlyTailIsDropped()
        testSessionKeepsOrderAndJoins()
        testSessionWithoutChunksReturnsNil()
        testSessionPropagatesFailure()
        testSampleDecoding()
    }

    // 220 Hz tone at moderate level, or digital silence.
    private static func tone(_ seconds: Double) -> [Int16] {
        (0..<Int(seconds * Double(rate))).map { index in
            Int16(0.3 * sin(2 * Double.pi * 220 * Double(index) / Double(rate)) * Double(Int16.max))
        }
    }

    private static func silence(_ seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * Double(rate)))
    }

    private static func feed(_ accumulator: inout ChunkAccumulator, _ audio: [Int16]) -> [[Int16]] {
        // Feed in small blocks like a real capture callback.
        var chunks: [[Int16]] = []
        var index = 0
        while index < audio.count {
            let end = min(index + 1_000, audio.count)
            chunks.append(contentsOf: accumulator.append(Array(audio[index..<end])))
            index = end
        }
        return chunks
    }

    private static func testChunkingAtPauses() {
        var accumulator = ChunkAccumulator(sampleRate: rate)
        let audio = tone(4) + silence(1) + tone(4) + silence(0.3) + tone(3)
        let chunks = feed(&accumulator, audio)
        TestSupport.expectEqual(chunks.count, 1)
        let firstSeconds = Double(chunks[0].count) / Double(rate)
        TestSupport.expect(firstSeconds > 4.0 && firstSeconds < 4.6, "first chunk ends just after the first phrase, got \(firstSeconds)")
        let tail = accumulator.flush()
        TestSupport.expect(tail != nil, "remaining phrases are flushed")
        // A 0.3 s gap is too short to cut, so the rest stays one chunk of ~7 s plus padding.
        let tailSeconds = Double(tail?.count ?? 0) / Double(rate)
        TestSupport.expect(tailSeconds > 7.0 && tailSeconds < 8.5, "tail keeps the short-gap phrases together, got \(tailSeconds)")
    }

    private static func testNoChunkForContinuousSpeech() {
        var accumulator = ChunkAccumulator(sampleRate: rate)
        let chunks = feed(&accumulator, tone(12))
        TestSupport.expectEqual(chunks.count, 0)
    }

    private static func testNoiseOnlyTailIsDropped() {
        var accumulator = ChunkAccumulator(sampleRate: rate)
        _ = feed(&accumulator, tone(4) + silence(1))
        TestSupport.expect(accumulator.flush() == nil, "silence after a cut is not a phrase")
    }

    private static func blocking<T>(_ work: @escaping () async throws -> T) -> Result<T, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }

    private static func pcmData(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            var little = sample.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func testSessionKeepsOrderAndJoins() {
        // The text identifies the chunk by its file size, and the delay is chosen so
        // chunks finish out of order: the joined result must still follow speech order.
        let session = ChunkedTranscriptionSession(sampleRate: rate) { url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let delayMilliseconds = max(0, 245_000 - size) / 1_000
            try await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
            return "\(size)"
        }
        let audio = tone(4) + silence(1) + tone(4) + silence(1) + tone(3)
        session.append(pcmData(audio))
        let outcome = blocking { try await session.finish() }
        if case .success(let text) = outcome {
            let sizes = (text ?? "").split(separator: " ").compactMap { Int($0) }
            TestSupport.expectEqual(sizes.count, 3)
            // Expected durations: phrase 1 ~4.15 s, phrase 2 ~5.0 s, tail ~3.85 s.
            TestSupport.expect(sizes[1] > sizes[0] && sizes[0] > sizes[2], "chunks keep speech order, got \(sizes)")
        } else {
            TestSupport.expect(false, "session should succeed")
        }
        TestSupport.expectEqual(session.chunkCount, 3)
    }

    private static func testSessionWithoutChunksReturnsNil() {
        let session = ChunkedTranscriptionSession(sampleRate: rate) { _ in "never" }
        session.append(pcmData(tone(2)))
        let outcome = blocking { try await session.finish() }
        if case .success(let text) = outcome {
            TestSupport.expect(text == nil, "no pause means the whole-file path is used")
        } else {
            TestSupport.expect(false, "should not fail")
        }
    }

    private struct ChunkFailure: Error {}

    private static func testSessionPropagatesFailure() {
        let session = ChunkedTranscriptionSession(sampleRate: rate) { _ in throw ChunkFailure() }
        session.append(pcmData(tone(4) + silence(1) + tone(2)))
        let outcome = blocking { try await session.finish() }
        if case .failure = outcome {} else {
            TestSupport.expect(false, "a failed chunk must surface so the caller falls back")
        }
    }

    private static func testSampleDecoding() {
        let decoded = ChunkAccumulator.samples(from: pcmData([1, -2, 300, Int16.min]))
        TestSupport.expectEqual(decoded, [1, -2, 300, Int16.min])
        let wav = WAVEncoding.wav(from: [0, 1], sampleRate: 16_000)
        TestSupport.expectEqual(wav.count, 48)
        TestSupport.expectEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    }
}
