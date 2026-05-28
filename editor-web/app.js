// GuiAssert Timeline Editor frontend.
//
// All rendering is vanilla DOM + a Canvas for the waveform. The page makes
// four kinds of API calls against the local backend:
//
//   GET  /api/script        — load the current driving script.
//   POST /api/script        — persist a new script after a drag.
//   POST /api/preview       — request a localised re-render after edits.
//   GET  /api/waveform      — fetch peak amplitudes for the audio canvas.
//
// State is intentionally module-local and minimal. The backend is the
// source of truth; the page mirrors it.

const state = {
  script: null,
  config: { timeScale: 100, fps: 30, canvasWidth: 1280, canvasHeight: 720 },
  totalDuration: 30,
};

const els = {
  statusText: document.getElementById("status-text"),
  statusElapsed: document.getElementById("status-elapsed"),
  ruler: document.getElementById("ruler"),
  trackAction: document.getElementById("track-action"),
  trackCaption: document.getElementById("track-caption"),
  waveform: document.getElementById("waveform"),
  scriptList: document.getElementById("script-list"),
  videoPlayer: document.getElementById("video-player"),
  currentTime: document.getElementById("current-time"),
  currentFrame: document.getElementById("current-frame"),
  footerPort: document.getElementById("footer-port"),
  footerPxPerSec: document.getElementById("footer-px-per-sec"),
  footerFps: document.getElementById("footer-fps"),
};

function setStatus(msg, elapsedMs) {
  els.statusText.textContent = msg;
  els.statusElapsed.textContent =
    elapsedMs === undefined ? "" : `${elapsedMs} ms`;
}

function setCurrentTime(seconds) {
  els.videoPlayer.dataset.currentTime = seconds.toFixed(3);
  els.currentTime.textContent = seconds.toFixed(2);
  const frames = Math.round(seconds * state.config.fps);
  els.currentFrame.textContent = String(frames);
}

function pxFromSeconds(seconds) {
  return seconds * state.config.timeScale;
}

function snap(value, step) {
  return Math.round(value / step) * step;
}

function captionWindows(script) {
  // Derive caption blocks from narration-bearing keyframes — mirrors the
  // Nim `captionsFromScript`.
  const out = [];
  const tl = script.timeline;
  for (let i = 0; i < tl.length; i++) {
    const kf = tl[i];
    if (typeof kf.narration !== "string" || kf.narration.length === 0)
      continue;
    let endTime;
    if (i + 1 < tl.length) endTime = tl[i + 1].time;
    else endTime = kf.time + Math.max(estimateNarrationSeconds(kf.narration), 1);
    out.push({
      keyframeIndex: i,
      text: kf.narration,
      startTime: kf.time,
      endTime,
    });
  }
  return out;
}

function estimateNarrationSeconds(text) {
  const tokens = text.trim().split(/\s+/).filter(Boolean);
  return (tokens.length / 150) * 60;
}

async function fetchConfig() {
  const resp = await fetch("/api/timescale");
  if (resp.ok) state.config = await resp.json();
  els.footerPxPerSec.textContent = String(state.config.timeScale);
  els.footerFps.textContent = String(state.config.fps);
}

async function fetchScript() {
  const resp = await fetch("/api/script");
  if (!resp.ok) throw new Error("script fetch failed");
  state.script = await resp.json();
  state.totalDuration = computeDuration(state.script);
  render();
}

function computeDuration(script) {
  let last = 5;
  for (const kf of script.timeline) {
    let end = kf.time;
    if (typeof kf.narration === "string")
      end += Math.max(estimateNarrationSeconds(kf.narration), 1);
    if (end > last) last = end;
  }
  return Math.max(last + 1, 10);
}

async function pushScript() {
  setStatus("saving…");
  const resp = await fetch("/api/script", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(state.script),
  });
  if (!resp.ok) {
    setStatus("save failed");
    return;
  }
  const out = await resp.json();
  setStatus(`saved · ${out.captions} captions`);
}

async function previewCaptionEdit(captionIndex, newText) {
  setStatus("rendering caption…");
  const resp = await fetch("/api/preview", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ kind: "caption", index: captionIndex, text: newText }),
  });
  if (!resp.ok) {
    setStatus("preview failed");
    return;
  }
  const out = await resp.json();
  setStatus(`preview · ${out.note}`, out.elapsedMs);
  els.videoPlayer.src = `/api/preview-file?path=${encodeURIComponent(out.previewPath)}&v=${Date.now()}`;
}

async function previewKeyframeMove(keyframeIndex, newTime) {
  setStatus("rendering keyframe…");
  const resp = await fetch("/api/preview", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ kind: "keyframe", index: keyframeIndex, time: newTime }),
  });
  if (!resp.ok) {
    setStatus("preview failed");
    return;
  }
  const out = await resp.json();
  setStatus("keyframe preview", out.elapsedMs);
  if (out.previewPath)
    els.videoPlayer.src = `/api/preview-file?path=${encodeURIComponent(out.previewPath)}&v=${Date.now()}`;
}

async function fetchWaveform() {
  const resp = await fetch("/api/waveform");
  if (!resp.ok) return;
  const data = await resp.json();
  drawWaveform(data.peaks || []);
}

function drawWaveform(peaks) {
  const canvas = els.waveform;
  const rect = canvas.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.floor(rect.width * dpr);
  canvas.height = Math.floor(rect.height * dpr);
  const ctx = canvas.getContext("2d");
  ctx.scale(dpr, dpr);
  ctx.fillStyle = "hsl(222, 40%, 14%)";
  ctx.fillRect(0, 0, rect.width, rect.height);
  if (!peaks.length) return;
  const mid = rect.height / 2;
  const barW = rect.width / peaks.length;
  ctx.fillStyle = "hsl(239, 84%, 67%)";
  for (let i = 0; i < peaks.length; i++) {
    const h = Math.max(2, peaks[i] * (rect.height - 4));
    ctx.fillRect(i * barW, mid - h / 2, Math.max(barW - 0.5, 1), h);
  }
}

function renderRuler(durationSec) {
  els.ruler.innerHTML = "";
  for (let s = 0; s <= durationSec; s++) {
    const tick = document.createElement("div");
    tick.className = "ruler-tick";
    tick.style.left = `${pxFromSeconds(s)}px`;
    els.ruler.appendChild(tick);
    if (s % 5 === 0) {
      const label = document.createElement("div");
      label.className = "ruler-tick-label";
      label.style.left = `${pxFromSeconds(s)}px`;
      label.textContent = `${s}s`;
      els.ruler.appendChild(label);
    }
  }
}

function renderActionTrack() {
  els.trackAction.innerHTML = "";
  state.script.timeline.forEach((kf, idx) => {
    const marker = document.createElement("div");
    marker.className = "keyframe-marker";
    marker.style.left = `${pxFromSeconds(kf.time)}px`;
    marker.dataset.keyframeIndex = String(idx);
    marker.title = `${kf.action} @ t=${kf.time.toFixed(2)}`;
    const tip = document.createElement("div");
    tip.className = "keyframe-marker-tip";
    tip.textContent = kf.time.toFixed(2);
    marker.appendChild(tip);
    attachKeyframeDrag(marker, idx, tip);
    els.trackAction.appendChild(marker);
  });
}

function attachKeyframeDrag(marker, keyframeIndex, tip) {
  let dragging = false;
  let startX = 0;
  let startLeft = 0;
  marker.addEventListener("mousedown", (e) => {
    e.preventDefault();
    dragging = true;
    startX = e.clientX;
    startLeft = parseFloat(marker.style.left);
    marker.classList.add("dragging");
  });
  document.addEventListener("mousemove", (e) => {
    if (!dragging) return;
    const dx = e.clientX - startX;
    const rawLeft = Math.max(0, startLeft + dx);
    const seconds = snap(rawLeft / state.config.timeScale, 0.1);
    marker.style.left = `${pxFromSeconds(seconds)}px`;
    tip.textContent = seconds.toFixed(2);
    setCurrentTime(seconds);
  });
  document.addEventListener("mouseup", async () => {
    if (!dragging) return;
    dragging = false;
    marker.classList.remove("dragging");
    const newLeft = parseFloat(marker.style.left);
    const newTime = snap(newLeft / state.config.timeScale, 0.1);
    state.script.timeline[keyframeIndex].time = newTime;
    await pushScript();
    await previewKeyframeMove(keyframeIndex, newTime);
    await fetchWaveform();
    state.totalDuration = computeDuration(state.script);
    renderRuler(state.totalDuration);
    renderCaptionTrack();
  });
}

function renderCaptionTrack() {
  els.trackCaption.innerHTML = "";
  const caps = captionWindows(state.script);
  caps.forEach((cap, idx) => {
    const block = document.createElement("div");
    block.className = "caption-block";
    block.style.left = `${pxFromSeconds(cap.startTime)}px`;
    block.style.width = `${pxFromSeconds(cap.endTime - cap.startTime)}px`;
    block.textContent = cap.text;
    block.dataset.captionIndex = String(idx);
    block.addEventListener("click", () => editCaption(block, idx, cap));
    els.trackCaption.appendChild(block);
  });
}

function editCaption(block, captionIndex, cap) {
  block.classList.add("editing");
  const input = document.createElement("input");
  input.type = "text";
  input.value = cap.text;
  block.textContent = "";
  block.appendChild(input);
  input.focus();
  input.select();
  const commit = async () => {
    const newText = input.value;
    block.classList.remove("editing");
    block.textContent = newText;
    state.script.timeline[cap.keyframeIndex].narration = newText;
    await pushScript();
    await previewCaptionEdit(captionIndex, newText);
    await fetchWaveform();
  };
  input.addEventListener("blur", commit);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      input.blur();
    }
  });
}

function renderScriptPanel() {
  els.scriptList.innerHTML = "";
  state.script.timeline.forEach((kf, idx) => {
    const li = document.createElement("li");
    li.innerHTML =
      `<span class="time">t=${kf.time.toFixed(2)}</span>` +
      `<span class="action">${kf.action}</span>` +
      `<span class="narration">${kf.narration ? escapeHtml(kf.narration) : ""}</span>`;
    li.addEventListener("click", () => setCurrentTime(kf.time));
    els.scriptList.appendChild(li);
  });
}

function escapeHtml(s) {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function render() {
  if (!state.script) return;
  state.totalDuration = computeDuration(state.script);
  renderRuler(state.totalDuration);
  renderActionTrack();
  renderCaptionTrack();
  renderScriptPanel();
  setCurrentTime(0);
}

async function main() {
  els.footerPort.textContent = String(location.port || 7180);
  try {
    await fetchConfig();
    await fetchScript();
    await fetchWaveform();
    setStatus("ready");
  } catch (e) {
    setStatus("error: " + e.message);
  }
}

window.addEventListener("DOMContentLoaded", main);
window.addEventListener("resize", () => {
  // Re-render waveform on resize so the canvas stays crisp.
  fetchWaveform();
});
