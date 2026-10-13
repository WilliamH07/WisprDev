"use strict";
const { contextBridge, ipcRenderer } = require("electron");

const INVOKE = new Set([
  "settings:get", "settings:save", "stats:get", "stats:reset", "history:get", "history:clear",
  "timings:last", "bench:transcription", "bench:cleanup", "hotkey:capture", "history:copy",
]);
const EVENTS = new Set(["timings", "state"]);

contextBridge.exposeInMainWorld("wisper", {
  invoke: (channel, payload) => {
    if (!INVOKE.has(channel)) throw new Error(`Canal non autorisé : ${channel}`);
    return ipcRenderer.invoke(channel, payload);
  },
  on: (channel, cb) => {
    if (!EVENTS.has(channel)) throw new Error(`Événement non autorisé : ${channel}`);
    ipcRenderer.on(channel, (_event, payload) => cb(payload));
  },
});
