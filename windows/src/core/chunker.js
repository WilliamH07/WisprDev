"use strict";

const { encodePcm16Wav } = require("./wav");

/**
 * Splits a live PCM16 mono stream into phrase-sized chunks at pauses so each chunk can
 * be transcribed while the user is still speaking. Port of ChunkAccumulator (macOS).
 */
class ChunkAccumulator {
  constructor(sampleRate, options = {}) {
    this.sampleRate = sampleRate;
    this.silenceSecondsToCut = options.silenceSecondsToCut ?? 0.6;
    this.minChunkSeconds = options.minChunkSeconds ?? 3.0;
    this.maxChunkSeconds = options.maxChunkSeconds ?? 25.0;
    this.paddingSeconds = options.paddingSeconds ?? 0.15;
    this.minSpeechSeconds = options.minSpeechSeconds ?? 0.3;
    this.frameSamples = Math.max(Math.floor(sampleRate / 50), 1); // 20 ms
    this.samples = [];
    this.partial = [];
    this.silenceRunFrames = 0;
    this.speechFrames = 0;
    this.peak = 0;
  }

  get frameSeconds() {
    return this.frameSamples / this.sampleRate;
  }

  /** Feeds samples and returns every chunk (Int16Array) that became complete. */
  append(newSamples) {
    const completed = [];
    for (let i = 0; i < newSamples.length; i += 1) this.partial.push(newSamples[i]);
    while (this.partial.length >= this.frameSamples) {
      const frame = this.partial.splice(0, this.frameSamples);
      const chunk = this._consume(frame);
      if (chunk) completed.push(chunk);
    }
    return completed;
  }

  /** Returns the remaining audio if it holds real speech, then resets. */
  flush() {
    if (this.partial.length > 0) {
      for (const s of this.partial) this.samples.push(s);
      this.partial = [];
    }
    const hasSpeech = this.speechFrames * this.frameSeconds >= this.minSpeechSeconds;
    const result = hasSpeech ? this._trimmedTail() : null;
    this._reset([]);
    return result;
  }

  _consume(frame) {
    const level = ChunkAccumulator.rms(frame);
    this.peak = Math.max(level, this.peak * 0.998);
    const silent = level < Math.max(0.006, this.peak * 0.18);
    for (const s of frame) this.samples.push(s);
    if (silent) {
      this.silenceRunFrames += 1;
    } else {
      this.silenceRunFrames = 0;
      this.speechFrames += 1;
    }

    const chunkSeconds = this.samples.length / this.sampleRate;
    const hasSpeech = this.speechFrames * this.frameSeconds >= this.minSpeechSeconds;
    if (
      hasSpeech &&
      chunkSeconds >= this.minChunkSeconds &&
      this.silenceRunFrames * this.frameSeconds >= this.silenceSecondsToCut
    ) {
      const paddedEnd = Math.min(
        this.samples.length,
        this.samples.length - this.silenceRunFrames * this.frameSamples + Math.floor(this.paddingSeconds * this.sampleRate)
      );
      const chunk = Int16Array.from(this.samples.slice(0, paddedEnd));
      this._reset(this.samples.slice(paddedEnd));
      return chunk;
    }
    if (chunkSeconds >= this.maxChunkSeconds) {
      const chunk = Int16Array.from(this.samples);
      this._reset([]);
      return chunk;
    }
    return null;
  }

  _reset(remainder) {
    this.samples = remainder;
    // The remainder is silence that followed the cut; it must not count as speech.
    this.silenceRunFrames = Math.floor(remainder.length / this.frameSamples);
    this.speechFrames = 0;
  }

  _trimmedTail() {
    const trailingSilence = this.silenceRunFrames * this.frameSamples;
    const keep = Math.min(
      this.samples.length,
      this.samples.length - trailingSilence + Math.floor(this.paddingSeconds * this.sampleRate)
    );
    return Int16Array.from(this.samples.slice(0, Math.max(keep, 0)));
  }

  static rms(frame) {
    if (frame.length === 0) return 0;
    let sum = 0;
    for (let i = 0; i < frame.length; i += 1) {
      const v = frame[i] / 32768;
      sum += v * v;
    }
    return Math.sqrt(sum / frame.length);
  }
}

/**
 * Transcribes phrase chunks in the background while the user is still speaking. At
 * release only the last phrase remains. `finish()` resolves to null when no pause ever
 * cut a chunk (the caller then transcribes the whole recording), and rejects when any
 * chunk failed (the caller falls back to the whole recording too).
 */
class ChunkedSession {
  constructor({ sampleRate = 24000, transcribe, options } = {}) {
    this.sampleRate = sampleRate;
    this.transcribe = transcribe;
    this.accumulator = new ChunkAccumulator(sampleRate, options);
    this.tasks = [];
    this.cancelled = false;
  }

  get chunkCount() {
    return this.tasks.length;
  }

  append(samples) {
    if (this.cancelled) return;
    for (const chunk of this.accumulator.append(samples)) this._dispatch(chunk);
  }

  async finish() {
    if (this.cancelled || this.tasks.length === 0) return null;
    const tail = this.accumulator.flush();
    if (tail) this._dispatch(tail);
    const parts = [];
    for (const task of this.tasks) {
      const text = String(await task).trim();
      if (text) parts.push(text);
    }
    return parts.join(" ");
  }

  cancel() {
    this.cancelled = true;
  }

  _dispatch(chunk) {
    const wav = encodePcm16Wav(chunk, this.sampleRate);
    const task = Promise.resolve().then(() => this.transcribe(wav));
    task.catch(() => {}); // a rejected, never-awaited task must not crash the process
    this.tasks.push(task);
  }
}

module.exports = { ChunkAccumulator, ChunkedSession };
