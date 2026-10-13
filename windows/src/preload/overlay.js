"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("overlayAPI", {
  onUpdate: (cb) => ipcRenderer.on("overlay-update", (_event, payload) => cb(payload)),
});
