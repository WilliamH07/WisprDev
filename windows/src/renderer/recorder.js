"use strict";

// Hidden window that owns the microphone. The stream stays warm for a few seconds after
// each dictation so the next one starts instantly, then it is closed (mic indicator off).
const WARM_MS = 15000;
let context = null;
let stream = null;
let node = null;
let closeTimer = null;
let flushResolve = null;

async function ensureCapture() {
  clearTimeout(closeTimer);
  if (context && stream && stream.active) {
    if (context.state === "suspended") await context.resume();
    return;
  }
  stream = await navigator.mediaDevices.getUserMedia({
    audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
  });
  context = new AudioContext({ sampleRate: 24000 });
  await context.audioWorklet.addModule("recorder-worklet.js");
  const source = context.createMediaStreamSource(stream);
  node = new AudioWorkletNode(context, "pcm-processor");
  node.port.onmessage = (event) => {
    if (event.data.audio) window.recorderAPI.sendAudio(event.data.audio);
    if (event.data.flushed && flushResolve) {
      flushResolve();
      flushResolve = null;
    }
  };
  source.connect(node);
}

function closeCapture() {
  if (stream) stream.getTracks().forEach((t) => t.stop());
  if (context) context.close();
  stream = null;
  context = null;
  node = null;
}

window.recorderAPI.onStart(async () => {
  try {
    await ensureCapture();
    node.port.postMessage("on");
    window.recorderAPI.sendReady();
  } catch (error) {
    window.recorderAPI.sendError(error && error.message ? error.message : "Micro indisponible");
  }
});

window.recorderAPI.onStop(async () => {
  if (node) {
    await new Promise((resolve) => {
      flushResolve = resolve;
      node.port.postMessage("off");
      setTimeout(resolve, 500); // never hang if the worklet is gone
    });
  }
  window.recorderAPI.sendStopped();
  clearTimeout(closeTimer);
  closeTimer = setTimeout(closeCapture, WARM_MS);
});
