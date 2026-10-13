"use strict";

const pill = document.getElementById("pill");
const label = document.getElementById("label");
const bars = [...document.querySelectorAll("#meter i")];
let hideTimer = null;

function setBars(level) {
  const height = Math.min(14, 3 + level * 120);
  bars.forEach((bar, i) => {
    const wobble = 0.55 + 0.45 * Math.sin(Date.now() / 90 + i * 1.3);
    bar.style.height = `${Math.max(3, height * wobble)}px`;
  });
}

window.overlayAPI.onUpdate((payload) => {
  clearTimeout(hideTimer);
  if (payload.type === "level") {
    setBars(payload.level);
    return;
  }
  if (payload.type === "hide") {
    pill.classList.add("hidden");
    return;
  }
  pill.className = `pill ${payload.style}`;
  label.textContent = payload.text;
  if (payload.autoHideMs) {
    hideTimer = setTimeout(() => pill.classList.add("hidden"), payload.autoHideMs);
  }
});
