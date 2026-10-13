"use strict";

/** Wraps mono PCM16 samples in a WAV container. */
function encodePcm16Wav(samples, sampleRate) {
  const dataSize = samples.length * 2;
  const buffer = Buffer.alloc(44 + dataSize);
  buffer.write("RIFF", 0, "ascii");
  buffer.writeUInt32LE(36 + dataSize, 4);
  buffer.write("WAVE", 8, "ascii");
  buffer.write("fmt ", 12, "ascii");
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20); // PCM
  buffer.writeUInt16LE(1, 22); // mono
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36, "ascii");
  buffer.writeUInt32LE(dataSize, 40);
  for (let i = 0; i < samples.length; i += 1) {
    buffer.writeInt16LE(samples[i], 44 + i * 2);
  }
  return buffer;
}

/** Amplitude-modulated tone used only to time engines. Contains no user audio. */
function syntheticSpeechWav(seconds = 4, sampleRate = 16000) {
  const count = Math.max(1, Math.floor(seconds * sampleRate));
  const samples = new Int16Array(count);
  for (let i = 0; i < count; i += 1) {
    const t = i / sampleRate;
    const envelope = 0.5 + 0.5 * Math.sin(2 * Math.PI * 3 * t);
    const value = 0.3 * envelope * Math.sin(2 * Math.PI * 220 * t);
    samples[i] = Math.round(Math.max(-1, Math.min(1, value)) * 32767);
  }
  return encodePcm16Wav(samples, sampleRate);
}

module.exports = { encodePcm16Wav, syntheticSpeechWav };
