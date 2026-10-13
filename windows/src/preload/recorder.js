"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("recorderAPI", {
  onStart: (cb) => ipcRenderer.on("rec-start", () => cb()),
  onStop: (cb) => ipcRenderer.on("rec-stop", () => cb()),
  sendAudio: (buffer) => ipcRenderer.send("rec-audio", buffer),
  sendReady: () => ipcRenderer.send("rec-ready"),
  sendStopped: () => ipcRenderer.send("rec-stopped"),
  sendError: (message) => ipcRenderer.send("rec-error", message),
});
