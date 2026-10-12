import Foundation

// MARK: - Chunking audio at natural pauses

/// Splits a live PCM16 mono stream into phrase-sized chunks at pauses, so each
/// chunk can be transcribed while the user is still speaking. Pure logic, no I/O.
struct ChunkAccumulator {
    let sampleRate: Int
    /// A pause this long ends a chunk.
    var silenceSecondsToCut = 0.6
    /// Never emit chunks shorter than this (avoids a flood of tiny requests).
    var minChunkSeconds = 3.0
    /// Emit unconditionally past this length so memory and request size stay bounded.
    var maxChunkSeconds = 25.0
    /// Kept after speech so word endings are not clipped.
    var paddingSeconds = 0.15
    /// Fewer speech frames than this is treated as noise, not a phrase.
    var minSpeechSeconds = 0.3

    private let frameSamples: Int
    private var samples: [Int16] = []
    private var partialFrame: [Int16] = []
    private var silenceRunFrames = 0
    private var speechFrames = 0
    private var peak = 0.0

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
        self.frameSamples = max(sampleRate / 50, 1) // 20 ms
    }

    private var frameSeconds: Double { Double(frameSamples) / Double(sampleRate) }

    /// Feeds new samples and returns every chunk that became complete.
    mutating func append(_ newSamples: [Int16]) -> [[Int16]] {
        var completed: [[Int16]] = []
        partialFrame.append(contentsOf: newSamples)
        while partialFrame.count >= frameSamples {
            let frame = Array(partialFrame.prefix(frameSamples))
            partialFrame.removeFirst(frameSamples)
            if let chunk = consume(frame: frame) { completed.append(chunk) }
        }
        return completed
    }

    /// Returns the remaining audio if it holds real speech, and resets.
    mutating func flush() -> [Int16]? {
        if !partialFrame.isEmpty {
            samples.append(contentsOf: partialFrame)
            partialFrame.removeAll()
        }
        defer { resetChunk(keeping: []) }
        guard Double(speechFrames) * frameSeconds >= minSpeechSeconds else { return nil }
        return trimmedTail(samples)
    }

    private mutating func consume(frame: [Int16]) -> [Int16]? {
        let rms = Self.rms(frame)
        peak = max(rms, peak * 0.998)
        let isSilent = rms < max(0.006, peak * 0.18)
        samples.append(contentsOf: frame)
        if isSilent {
            silenceRunFrames += 1
        } else {
            silenceRunFrames = 0
            speechFrames += 1
        }

        let chunkSeconds = Double(samples.count) / Double(sampleRate)
        let hasSpeech = Double(speechFrames) * frameSeconds >= minSpeechSeconds
        if hasSpeech,
           chunkSeconds >= minChunkSeconds,
           Double(silenceRunFrames) * frameSeconds >= silenceSecondsToCut {
            let paddedEnd = min(samples.count, samples.count - silenceRunFrames * frameSamples + Int(paddingSeconds * Double(sampleRate)))
            let chunk = Array(samples[0..<paddedEnd])
            resetChunk(keeping: Array(samples[paddedEnd...]))
            return chunk
        }
        if chunkSeconds >= maxChunkSeconds {
            let chunk = samples
            resetChunk(keeping: [])
            return chunk
        }
        return nil
    }

    private mutating func resetChunk(keeping remainder: [Int16]) {
        samples = remainder
        // The remainder is silence that followed the cut; it must not count as speech.
        silenceRunFrames = remainder.count / frameSamples
        speechFrames = 0
    }

    private func trimmedTail(_ audio: [Int16]) -> [Int16] {
        let trailingSilence = silenceRunFrames * frameSamples
        let keep = min(audio.count, audio.count - trailingSilence + Int(paddingSeconds * Double(sampleRate)))
        return Array(audio[0..<max(keep, 0)])
    }

    static func rms(_ frame: [Int16]) -> Double {
        guard !frame.isEmpty else { return 0 }
        var sum = 0.0
        for sample in frame {
            let value = Double(sample) / 32768
            sum += value * value
        }
        return (sum / Double(frame.count)).squareRoot()
    }

    /// Little-endian PCM16 bytes to samples (alignment-safe).
    static func samples(from data: Data) -> [Int16] {
        let count = data.count / 2
        var result = [Int16]()
        result.reserveCapacity(count)
        let base = data.startIndex
        for index in 0..<count {
            let low = UInt16(data[base + index * 2])
            let high = UInt16(data[base + index * 2 + 1])
            result.append(Int16(bitPattern: low | (high << 8)))
        }
        return result
    }
}

enum WAVEncoding {
    /// Wraps PCM16 mono samples in a WAV container.
    static func wav(from samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data()
        data.reserveCapacity(44 + dataSize)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        return data
    }
}

// MARK: - Transcribing chunks while recording

/// Transcribes phrase chunks in the background while the user is still speaking.
/// At release only the last phrase remains, which is what makes long dictations
/// feel instant. Short dictations that never reach a pause are not handled here
/// (`finish()` returns nil) and use the normal whole-file path unchanged.
final class ChunkedTranscriptionSession: @unchecked Sendable {
    typealias Transcribe = @Sendable (URL) async throws -> String

    private let sampleRate: Int
    private let transcribe: Transcribe
    private let lock = NSLock()
    private var accumulator: ChunkAccumulator
    private var tasks: [Task<String, Error>] = []
    private var cancelled = false

    init(sampleRate: Int = 24_000, transcribe: @escaping Transcribe) {
        self.sampleRate = sampleRate
        self.accumulator = ChunkAccumulator(sampleRate: sampleRate)
        self.transcribe = transcribe
    }

    /// Number of phrase chunks sent so far (including the tail after `finish()`).
    var chunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    /// Called from the audio thread with 24 kHz mono PCM16 bytes.
    func append(_ pcm16: Data) {
        let newSamples = ChunkAccumulator.samples(from: pcm16)
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        for chunk in accumulator.append(newSamples) {
            tasks.append(makeTask(for: chunk))
        }
    }

    /// Returns the full transcript from chunks, or nil when no pause ever cut a
    /// chunk (the caller should then transcribe the whole recording as before).
    /// Throws if any chunk failed, so the caller can fall back to the whole file.
    func finish() async throws -> String? {
        let pending: [Task<String, Error>]? = {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, !tasks.isEmpty else { return nil }
            if let tail = accumulator.flush() {
                tasks.append(makeTask(for: tail))
            }
            return tasks
        }()
        guard let pending else { return nil }

        return try await withTaskCancellationHandler {
            var parts: [String] = []
            for task in pending {
                let text = try await task.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
            }
            return parts.joined(separator: " ")
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = tasks
        lock.unlock()
        for task in running { task.cancel() }
    }

    private func makeTask(for chunk: [Int16]) -> Task<String, Error> {
        let rate = sampleRate
        let transcribe = self.transcribe
        return Task {
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("wisper-chunk-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            try WAVEncoding.wav(from: chunk, sampleRate: rate).write(to: fileURL, options: .atomic)
            return try await transcribe(fileURL)
        }
    }
}
