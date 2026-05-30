// GuiAssert Avatar Timeline Editor — frontend
//
// State model:
//   sources       : [{id, label, kind, path, width, height}]
//   track         : { source_video, keyframes: [...] }
//   selectedKf    : index into track.keyframes (or -1)
//   sourceDims    : {w, h}   pixel dimensions of the avatar source
//   canvasDims    : {w, h}   pixel dimensions of the composed canvas
//   duration      : seconds  estimated by avatar source video metadata
//
// Wire protocol:
//   GET  /api/sources
//   GET  /api/avatar-track
//   POST /api/avatar-track
//   GET  /api/composite
//   GET  /api/preview-file?path=<absolute>
//   GET  /api/timescale

(() => {
  const $ = (id) => document.getElementById(id);
  const STATUS = $("status-text");
  const ELAPSED = $("status-elapsed");
  const SRC_VIDEO = $("source-video");
  const SRC_OVERLAY = $("source-overlay");
  const SRC_STAGE = $("source-stage");
  const SRC_INFO = $("source-rect-info");
  const COMP_VIDEO = $("composite-video");
  const COMP_OVERLAY = $("composite-overlay");
  const COMP_STAGE = $("composite-stage");
  const COMP_INFO = $("composite-rect-info");
  const PICKER = $("source-picker");
  const KF_RULER = $("kf-ruler");
  const KF_TRACK = $("kf-track");
  const KF_INSPECTOR = $("kf-inspector");
  const FOOTER_CANVAS = $("footer-canvas");
  const FOOTER_SRC = $("footer-src");
  const FOOTER_KFS = $("footer-kfs");
  const FOOTER_PROJECT = $("footer-project");
  const STALE_BANNER = $("stale-banner");
  const STALE_MSG = $("stale-banner-msg");
  const STALE_RENDER = $("stale-banner-render");
  const STALE_DISMISS = $("stale-banner-dismiss");
  const RM_REFRESH = $("rm-refresh");
  const STAGES_BODY = $("render-stages-body");
  const RENDER_FOOTER = $("render-footer");
  const OPT_CAPTIONS = $("opt-captions");
  const OPT_LOCAL_MODEL = $("opt-local-model");
  const OPT_COMMERCIAL = $("opt-commercial");

  const SVG_NS = "http://www.w3.org/2000/svg";
  const PX_PER_SEC = 100;

  const state = {
    sources: [],
    track: { source_video: "", keyframes: [] },
    selectedKf: -1,
    sourceDims: { w: 0, h: 0 },
    canvasDims: { w: 1280, h: 720 },
    duration: 10,
    inflight: null,
    history: { past: [], future: [], limit: 100 },
    renderState: { scriptPath: "", projectDir: "", stages: [] },
    renderOptions: {
      captions: true, audioMode: "head",
      localHeadModel: "sadtalker", commercialProvider: "heygen",
    },
    bannerDismissed: false,
  };

  // ---------------------------------------------------------------- history

  function snapshotTrack() {
    return JSON.stringify(state.track);
  }

  // Record the *current* state before a mutation lands so an Undo can
  // restore exactly this state.  Clears the redo stack.
  function recordUndo() {
    state.history.past.push(snapshotTrack());
    if (state.history.past.length > state.history.limit) {
      state.history.past.shift();
    }
    state.history.future.length = 0;
  }

  function applyHistoryState(serialized) {
    state.track = JSON.parse(serialized);
    if (state.selectedKf >= state.track.keyframes.length) {
      state.selectedKf = state.track.keyframes.length - 1;
    }
    if (state.selectedKf < 0 && state.track.keyframes.length > 0) {
      state.selectedKf = 0;
    }
    rerenderEverything();
    saveTrackImmediate();
  }

  function undo() {
    if (state.history.past.length === 0) return;
    const prev = state.history.past.pop();
    state.history.future.push(snapshotTrack());
    applyHistoryState(prev);
    setStatus("undo");
  }

  function redo() {
    if (state.history.future.length === 0) return;
    const next = state.history.future.pop();
    state.history.past.push(snapshotTrack());
    applyHistoryState(next);
    setStatus("redo");
  }

  // -------------------------------------------------------- aspect locking

  // Force `dst.w / dst.h == src.w / src.h` on the active keyframe.
  // `which` tells which side the user just changed — the *other* side's
  // height is recomputed so its width stays where the user left it.
  // Zero-sized crops are interpreted as "to the source's right/bottom edge",
  // which only the renderer knows about; for aspect-sync we treat them as
  // the full source extent.
  function effectiveCrop(kf) {
    const w = kf.src_crop.w > 0
      ? kf.src_crop.w
      : Math.max(state.sourceDims.w - kf.src_crop.x, 1);
    const h = kf.src_crop.h > 0
      ? kf.src_crop.h
      : Math.max(state.sourceDims.h - kf.src_crop.y, 1);
    return { w, h };
  }

  function syncAspect(kf, which) {
    const ec = effectiveCrop(kf);
    const sr = kf.src_crop;
    const dr = kf.dst_rect;
    if (ec.w <= 0 || ec.h <= 0 || dr.w <= 0 || dr.h <= 0) return;
    if (which === "src") {
      const aspect = ec.w / ec.h;
      dr.h = dr.w / aspect;
      // If dst overflows the canvas, scale both dst dims down to fit.
      if (dr.y + dr.h > state.canvasDims.h) {
        const scale = (state.canvasDims.h - dr.y) / dr.h;
        if (scale > 0) {
          dr.h *= scale;
          dr.w *= scale;
        }
      }
    } else {
      const aspect = dr.w / dr.h;
      // Adjust crop's height so it matches dst's aspect.  We keep the
      // crop's stored `w` field as-is (which may be 0 == full); if it's
      // a fractional crop we recompute h in source pixels.
      if (sr.w > 0) {
        sr.h = sr.w / aspect;
      } else {
        // sr.w means "full source width minus x" — set sr.h such that
        // the *effective* aspect matches.
        sr.h = ec.w / aspect;
      }
      if (sr.y + sr.h > state.sourceDims.h && state.sourceDims.h > 0) {
        const scale = (state.sourceDims.h - sr.y) / sr.h;
        if (scale > 0) {
          sr.h *= scale;
          if (sr.w > 0) sr.w *= scale;
        }
      }
    }
  }

  // ------------------------------------------------------------- helpers

  function setStatus(text, ms) {
    STATUS.textContent = text;
    if (typeof ms === "number") ELAPSED.textContent = `${ms} ms`;
    else ELAPSED.textContent = "";
  }

  async function fetchJson(url, opts) {
    const r = await fetch(url, opts);
    if (!r.ok) throw new Error(`${url}: ${r.status} ${await r.text()}`);
    return r.json();
  }

  function fileUrl(absPath) {
    return `/api/preview-file?path=${encodeURIComponent(absPath)}`;
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }
  function fmtNum(v) {
    if (typeof v !== "number") return String(v);
    if (!Number.isFinite(v)) return "NaN";
    return Number.isInteger(v) ? String(v) : v.toFixed(1);
  }

  function videoContentBox(videoEl, stageEl) {
    // The <video> uses object-fit: contain (max-width/height); compute the
    // actual rendered box within the stage so we can map mouse → video pixels.
    const stage = stageEl.getBoundingClientRect();
    const vw = videoEl.videoWidth || 1;
    const vh = videoEl.videoHeight || 1;
    const aspect = vw / vh;
    const stageAspect = stage.width / stage.height;
    let w, h;
    if (stageAspect > aspect) { h = stage.height; w = h * aspect; }
    else                       { w = stage.width;  h = w / aspect; }
    return {
      left: stage.left + (stage.width - w) / 2,
      top:  stage.top  + (stage.height - h) / 2,
      width: w,
      height: h,
      vw, vh,
    };
  }

  // Map a rectangle in *video pixel* coordinates to <svg> user units.
  // The SVG covers the same area as the stage, so we set its viewBox to
  // [0, 0, vw, vh] and shift+scale via a transform group to align with
  // the actual rendered content box.
  function syncOverlayViewBox(svgEl, videoEl, stageEl) {
    const box = videoContentBox(videoEl, stageEl);
    const stage = stageEl.getBoundingClientRect();
    svgEl.setAttribute("viewBox", `0 0 ${stage.width} ${stage.height}`);
    svgEl.dataset.boxLeft = (box.left - stage.left).toFixed(2);
    svgEl.dataset.boxTop  = (box.top  - stage.top ).toFixed(2);
    svgEl.dataset.boxW    = box.width.toFixed(2);
    svgEl.dataset.boxH    = box.height.toFixed(2);
    svgEl.dataset.vw      = box.vw;
    svgEl.dataset.vh      = box.vh;
  }

  function pxToSrc(svgEl, px, py) {
    const bl = parseFloat(svgEl.dataset.boxLeft);
    const bt = parseFloat(svgEl.dataset.boxTop);
    const bw = parseFloat(svgEl.dataset.boxW);
    const bh = parseFloat(svgEl.dataset.boxH);
    const vw = parseFloat(svgEl.dataset.vw);
    const vh = parseFloat(svgEl.dataset.vh);
    return {
      x: ((px - bl) / bw) * vw,
      y: ((py - bt) / bh) * vh,
    };
  }

  function srcToPx(svgEl, sx, sy) {
    const bl = parseFloat(svgEl.dataset.boxLeft);
    const bt = parseFloat(svgEl.dataset.boxTop);
    const bw = parseFloat(svgEl.dataset.boxW);
    const bh = parseFloat(svgEl.dataset.boxH);
    const vw = parseFloat(svgEl.dataset.vw);
    const vh = parseFloat(svgEl.dataset.vh);
    return {
      x: bl + (sx / vw) * bw,
      y: bt + (sy / vh) * bh,
    };
  }

  // -------------------------------------------------------- rect overlay

  // `kind` = "src" | "dst"; updates state.track.keyframes[selectedKf].(srcCrop|dstRect)
  function renderRect(svgEl, kind) {
    while (svgEl.firstChild) svgEl.removeChild(svgEl.firstChild);
    if (state.selectedKf < 0) return;
    const kf = state.track.keyframes[state.selectedKf];
    const rect = kind === "src" ? kf.src_crop : kf.dst_rect;
    const bl = parseFloat(svgEl.dataset.boxLeft);
    const bt = parseFloat(svgEl.dataset.boxTop);
    const bw = parseFloat(svgEl.dataset.boxW);
    const bh = parseFloat(svgEl.dataset.boxH);
    const vw = parseFloat(svgEl.dataset.vw);
    const vh = parseFloat(svgEl.dataset.vh);
    if (!vw || !vh) return;

    const x = bl + (rect.x / vw) * bw;
    const y = bt + (rect.y / vh) * bh;
    let w = (rect.w / vw) * bw;
    let h = (rect.h / vh) * bh;
    // Zero-or-negative crop width => extend to right/bottom edge.
    if (rect.w <= 0) w = bw + bl - x;
    if (rect.h <= 0) h = bh + bt - y;

    const r = document.createElementNS(SVG_NS, "rect");
    r.setAttribute("x", x);
    r.setAttribute("y", y);
    r.setAttribute("width", Math.max(w, 4));
    r.setAttribute("height", Math.max(h, 4));
    r.setAttribute("class", kind === "src" ? "crop-rect" : "dst-rect");
    svgEl.appendChild(r);

    // Resize handles at the 4 corners.
    const HS = 7;
    const corners = [
      ["nw", x,         y],
      ["ne", x + w,     y],
      ["sw", x,         y + h],
      ["se", x + w,     y + h],
    ];
    const handles = [];
    for (const [name, cx, cy] of corners) {
      const h = document.createElementNS(SVG_NS, "rect");
      h.setAttribute("x", cx - HS / 2);
      h.setAttribute("y", cy - HS / 2);
      h.setAttribute("width", HS);
      h.setAttribute("height", HS);
      h.setAttribute("class", `rect-handle ${name}`);
      h.dataset.handle = name;
      svgEl.appendChild(h);
      handles.push(h);
    }

    let drag = null;
    const onDown = (e) => {
      const target = e.target;
      const isHandle = target.classList && target.classList.contains("rect-handle");
      const isBody = target === r;
      if (!isHandle && !isBody) return;
      e.preventDefault();
      const stageRect = svgEl.parentNode.getBoundingClientRect();
      recordUndo();
      drag = {
        kind: isHandle ? target.dataset.handle : "move",
        startX: e.clientX, startY: e.clientY,
        origRect: { x: rect.x, y: rect.y, w: rect.w, h: rect.h },
        stage: stageRect,
        isResize: isHandle,
      };
      window.addEventListener("mousemove", onMove);
      window.addEventListener("mouseup", onUp);
    };
    const onMove = (e) => {
      if (!drag) return;
      const dxPx = e.clientX - drag.startX;
      const dyPx = e.clientY - drag.startY;
      const scaleX = vw / bw, scaleY = vh / bh;
      const dx = dxPx * scaleX;
      const dy = dyPx * scaleY;
      const orig = drag.origRect;
      let nx = orig.x, ny = orig.y;
      let nw = orig.w > 0 ? orig.w : vw - orig.x;
      let nh = orig.h > 0 ? orig.h : vh - orig.y;
      switch (drag.kind) {
        case "move": nx += dx; ny += dy; break;
        case "nw":   nx += dx; ny += dy; nw -= dx; nh -= dy; break;
        case "ne":              ny += dy; nw += dx; nh -= dy; break;
        case "sw":   nx += dx;            nw -= dx; nh += dy; break;
        case "se":                        nw += dx; nh += dy; break;
      }
      nw = Math.max(8, nw);
      nh = Math.max(8, nh);
      if (drag.isResize) {
        // Aspect-lock corner resizes: pick whichever axis the user
        // dragged proportionally further and force the other to match
        // the original aspect.  This keeps the image from stretching.
        const aspect = (orig.w > 0 ? orig.w : 1) / (orig.h > 0 ? orig.h : 1);
        const scaleW = nw / Math.max(1, orig.w);
        const scaleH = nh / Math.max(1, orig.h);
        const scale = Math.abs(scaleW - 1) >= Math.abs(scaleH - 1) ? scaleW : scaleH;
        nw = Math.max(8, (orig.w > 0 ? orig.w : 1) * scale);
        nh = nw / aspect;
        // If the handle is anchored on the top or left edge, the
        // anchor point moves so re-derive x/y from the original anchor.
        if (drag.kind === "nw") {
          nx = orig.x + orig.w - nw;
          ny = orig.y + orig.h - nh;
        } else if (drag.kind === "ne") {
          ny = orig.y + orig.h - nh;
        } else if (drag.kind === "sw") {
          nx = orig.x + orig.w - nw;
        }
      }
      if (kind === "src") {
        nx = clamp(nx, 0, vw - nw);
        ny = clamp(ny, 0, vh - nh);
      } else {
        nx = clamp(nx, 0, state.canvasDims.w - nw);
        ny = clamp(ny, 0, state.canvasDims.h - nh);
        nw = Math.min(nw, state.canvasDims.w - nx);
        nh = Math.min(nh, state.canvasDims.h - ny);
      }
      const target = state.track.keyframes[state.selectedKf];
      const t = kind === "src" ? target.src_crop : target.dst_rect;
      t.x = nx; t.y = ny; t.w = nw; t.h = nh;
      // Propagate the new aspect to the other rectangle so the image
      // isn't stretched in the composite.
      syncAspect(target, kind);
      rerenderEverything();
    };
    const onUp = () => {
      if (!drag) return;
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      drag = null;
      saveTrack();
    };
    r.addEventListener("mousedown", onDown);
    handles.forEach((h) => h.addEventListener("mousedown", onDown));
  }

  function updateRectInfo() {
    if (state.selectedKf < 0) {
      SRC_INFO.textContent = "src crop —";
      COMP_INFO.textContent = "dst rect —";
      return;
    }
    const kf = state.track.keyframes[state.selectedKf];
    SRC_INFO.textContent =
      `src crop  x=${fmtNum(kf.src_crop.x)}  y=${fmtNum(kf.src_crop.y)}  ` +
      `w=${fmtNum(kf.src_crop.w)}  h=${fmtNum(kf.src_crop.h)}  (source px)`;
    COMP_INFO.textContent =
      `dst rect  x=${fmtNum(kf.dst_rect.x)}  y=${fmtNum(kf.dst_rect.y)}  ` +
      `w=${fmtNum(kf.dst_rect.w)}  h=${fmtNum(kf.dst_rect.h)}  (canvas px)`;
  }

  // -------------------------------------------------------- inspector

  function updateInspector() {
    KF_INSPECTOR.innerHTML = "";
    if (state.selectedKf < 0) {
      const empty = document.createElement("div");
      empty.className = "kf-empty";
      empty.textContent = "no keyframe selected";
      KF_INSPECTOR.appendChild(empty);
      return;
    }
    const kf = state.track.keyframes[state.selectedKf];
    const fields = [
      { key: "time",            label: "time (s)",   step: 0.05 },
      { key: "src_crop.x",      label: "src x",      step: 4 },
      { key: "src_crop.y",      label: "src y",      step: 4 },
      { key: "src_crop.w",      label: "src w",      step: 4 },
      { key: "src_crop.h",      label: "src h",      step: 4 },
      { key: "dst_rect.x",      label: "dst x",      step: 4 },
      { key: "dst_rect.y",      label: "dst y",      step: 4 },
      { key: "dst_rect.w",      label: "dst w",      step: 4 },
      { key: "dst_rect.h",      label: "dst h",      step: 4 },
      { key: "key_method",      label: "key method", select: ["chroma", "color", "luma"] },
      { key: "key_color",       label: "key color",  text: true },
      { key: "key_similarity",  label: "similarity", step: 0.01 },
      { key: "key_blend",       label: "blend",      step: 0.01 },
      { key: "luma_threshold",  label: "luma thr",   step: 0.01 },
      { key: "luma_tolerance",  label: "luma tol",   step: 0.01 },
      { key: "despill",         label: "despill",    bool: true },
    ];
    for (const f of fields) {
      const wrap = document.createElement("div");
      wrap.className = "kf-field";
      const lbl = document.createElement("label");
      lbl.textContent = f.label;
      wrap.appendChild(lbl);
      const cur = readPath(kf, f.key);
      let inp;
      if (f.select) {
        inp = document.createElement("select");
        for (const v of f.select) {
          const o = document.createElement("option");
          o.value = v; o.textContent = v;
          if (v === cur) o.selected = true;
          inp.appendChild(o);
        }
      } else if (f.bool) {
        inp = document.createElement("input");
        inp.type = "checkbox";
        inp.checked = !!cur;
      } else if (f.text) {
        inp = document.createElement("input");
        inp.type = "text";
        inp.value = cur ?? "";
      } else {
        inp = document.createElement("input");
        inp.type = "number";
        inp.step = String(f.step);
        inp.value = (typeof cur === "number" ? cur : 0).toString();
      }
      inp.addEventListener("change", () => {
        recordUndo();
        const v = f.bool ? inp.checked : (f.select || f.text ? inp.value : parseFloat(inp.value));
        writePath(kf, f.key, v);
        // Aspect-sync if the user changed a rect dimension.
        if (f.key.startsWith("src_crop.")) syncAspect(kf, "src");
        else if (f.key.startsWith("dst_rect.")) syncAspect(kf, "dst");
        rerenderEverything();
        saveTrack();
      });
      wrap.appendChild(inp);
      KF_INSPECTOR.appendChild(wrap);
    }
    const actions = document.createElement("div");
    actions.className = "kf-actions";
    const dup = document.createElement("button");
    dup.className = "kf-btn"; dup.textContent = "duplicate";
    dup.onclick = () => {
      recordUndo();
      const clone = JSON.parse(JSON.stringify(kf));
      clone.time += 1.0;
      state.track.keyframes.splice(state.selectedKf + 1, 0, clone);
      state.selectedKf += 1;
      rerenderEverything();
      saveTrack();
    };
    const del = document.createElement("button");
    del.className = "kf-btn danger"; del.textContent = "delete";
    del.onclick = () => {
      if (state.track.keyframes.length <= 1) return;
      recordUndo();
      state.track.keyframes.splice(state.selectedKf, 1);
      state.selectedKf = Math.min(state.selectedKf, state.track.keyframes.length - 1);
      rerenderEverything();
      saveTrack();
    };
    actions.appendChild(dup);
    actions.appendChild(del);
    KF_INSPECTOR.appendChild(actions);
  }

  function readPath(obj, path) {
    return path.split(".").reduce((o, k) => (o == null ? o : o[k]), obj);
  }
  function writePath(obj, path, value) {
    const parts = path.split(".");
    const last = parts.pop();
    const parent = parts.reduce((o, k) => o[k] = o[k] || {}, obj);
    parent[last] = value;
  }

  // -------------------------------------------------------- timeline

  function renderTimeline() {
    KF_RULER.innerHTML = "";
    KF_TRACK.innerHTML = "";
    const duration = Math.max(state.duration, 1);
    const width = KF_TRACK.clientWidth || 600;
    const scale = width / duration;
    for (let s = 0; s <= duration; s += 1) {
      const tick = document.createElement("div");
      tick.className = "ruler-tick";
      tick.style.left = (s * scale + 90) + "px"; // +90 for label gutter
      tick.textContent = `${s}s`;
      KF_RULER.appendChild(tick);
    }
    for (let i = 0; i < state.track.keyframes.length; i++) {
      const kf = state.track.keyframes[i];
      const d = document.createElement("div");
      d.className = "kf-diamond" + (i === state.selectedKf ? " active" : "");
      d.style.left = (clamp(kf.time, 0, duration) * scale) + "px";
      d.title = `t = ${kf.time.toFixed(2)}s`;
      d.onmousedown = (e) => startKfDrag(e, i, scale, duration);
      KF_TRACK.appendChild(d);
    }
    FOOTER_KFS.textContent = `${state.track.keyframes.length} keyframes`;
  }

  function startKfDrag(e, index, scale, duration) {
    e.preventDefault();
    state.selectedKf = index;
    rerenderEverything();
    recordUndo();
    const startX = e.clientX;
    const origT = state.track.keyframes[index].time;
    const onMove = (ev) => {
      const dt = (ev.clientX - startX) / scale;
      state.track.keyframes[index].time =
        clamp(origT + dt, 0, duration);
      state.track.keyframes.sort((a, b) => a.time - b.time);
      // re-find the dragged kf after sort
      state.selectedKf = state.track.keyframes.findIndex(
        (k) => k === state.track.keyframes[state.selectedKf]
      );
      renderTimeline();
      updateInspector();
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      saveTrack();
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  }

  KF_TRACK.addEventListener("dblclick", (e) => {
    const rect = KF_TRACK.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const duration = Math.max(state.duration, 1);
    const width = KF_TRACK.clientWidth || 600;
    const scale = width / duration;
    const t = clamp(x / scale, 0, duration);
    recordUndo();
    // Clone the last active keyframe geometry so the new one is editable.
    const tmpl = state.track.keyframes[
      Math.max(0, state.selectedKf >= 0 ? state.selectedKf : state.track.keyframes.length - 1)
    ] || defaultKf();
    const fresh = JSON.parse(JSON.stringify(tmpl));
    fresh.time = t;
    state.track.keyframes.push(fresh);
    state.track.keyframes.sort((a, b) => a.time - b.time);
    state.selectedKf = state.track.keyframes.findIndex(
      (k) => Math.abs(k.time - t) < 1e-6
    );
    rerenderEverything();
    saveTrack();
  });

  function defaultKf() {
    return {
      time: 0,
      src_crop: { x: 0, y: 0, w: 0, h: 0 },
      dst_rect: { x: 0, y: 0, w: 320, h: 320 },
      key_method: "chroma",
      key_color: "0x00ff00",
      key_similarity: 0.18,
      key_blend: 0.10,
      luma_threshold: 0.9,
      luma_tolerance: 0.05,
      despill: true,
      despill_type: "green",
    };
  }

  // -------------------------------------------------------- save

  let saveTimer = null;
  async function postTrack() {
    setStatus("re-rendering…");
    const t0 = performance.now();
    const r = await fetchJson("/api/avatar-track", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(state.track),
    });
    const ms = Math.round(performance.now() - t0);
    setStatus("ready", ms);
    const u = fileUrl(r.compositePath) + "&v=" + Date.now();
    COMP_VIDEO.src = u;
  }

  function saveTrack() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      postTrack().catch((e) => setStatus("ERROR: " + e.message));
    }, 120);
  }

  function saveTrackImmediate() {
    clearTimeout(saveTimer);
    postTrack().catch((e) => setStatus("ERROR: " + e.message));
  }

  // -------------------------------------------------------- redraw

  function rerenderEverything() {
    syncOverlayViewBox(SRC_OVERLAY, SRC_VIDEO, SRC_STAGE);
    syncOverlayViewBox(COMP_OVERLAY, COMP_VIDEO, COMP_STAGE);
    renderRect(SRC_OVERLAY, "src");
    renderRect(COMP_OVERLAY, "dst");
    renderTimeline();
    updateInspector();
    updateRectInfo();
  }

  // -------------------------------------------------------- render manager

  function fmtBytes(n) {
    if (n <= 0) return "—";
    const units = ["B", "kB", "MB", "GB"];
    let i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return `${n.toFixed(n >= 10 ? 0 : 1)} ${units[i]}`;
  }
  function fmtMtime(seconds) {
    if (!seconds) return "—";
    const d = new Date(seconds * 1000);
    const pad = (x) => String(x).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  function renderStagesTable() {
    STAGES_BODY.innerHTML = "";
    for (const s of state.renderState.stages) {
      const tr = document.createElement("tr");
      const label = document.createElement("td");
      label.textContent = s.stage;
      const status = document.createElement("td");
      status.textContent = s.status;
      status.className = `status-${s.status}`;
      const size = document.createElement("td");
      size.textContent = fmtBytes(s.size);
      const updated = document.createElement("td");
      updated.textContent = fmtMtime(s.mtime);
      const actions = document.createElement("td");
      actions.className = "actions";
      const btn = document.createElement("button");
      btn.className = "kf-btn";
      btn.textContent = s.status === "fresh" ? "re-render" : "render";
      btn.dataset.stage = s.stage;
      btn.onclick = () => renderStage(s.stage, btn);
      actions.appendChild(btn);
      tr.append(label, status, size, updated, actions);
      STAGES_BODY.appendChild(tr);
    }
    RENDER_FOOTER.textContent = state.renderState.projectDir
      ? `project: ${state.renderState.projectDir}`
      : "no project";
    FOOTER_PROJECT.textContent = state.renderState.projectDir || "no project";
    // Banner: surface when automation stage isn't fresh.
    const auto = state.renderState.stages.find((s) => s.stage === "automation");
    if (auto && (auto.status === "stale" || auto.status === "missing") &&
        !state.bannerDismissed && state.renderState.scriptPath) {
      STALE_BANNER.classList.remove("hidden");
      STALE_MSG.textContent =
        auto.status === "missing"
          ? "Automation hasn't been recorded yet — record it now to start the pipeline."
          : "Automation is stale: timeline actions have changed since the last screencast.";
    } else {
      STALE_BANNER.classList.add("hidden");
    }
  }

  async function refreshRenderState() {
    try {
      const s = await fetchJson("/api/render-state");
      state.renderState = s;
      renderStagesTable();
    } catch (e) {
      RENDER_FOOTER.textContent = "render-state error: " + e.message;
    }
  }

  async function renderStage(stage, btn) {
    const stageCell = btn.closest("tr").querySelector("td:nth-child(2)");
    const orig = btn.textContent;
    btn.disabled = true;
    btn.textContent = "rendering…";
    if (stageCell) {
      stageCell.textContent = "running";
      stageCell.className = "status-running";
    }
    try {
      setStatus(`rendering ${stage}…`);
      const t0 = performance.now();
      const r = await fetchJson(
        `/api/render?stage=${encodeURIComponent(stage)}`,
        { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }
      );
      const ms = Math.round(performance.now() - t0);
      setStatus("ready", ms);
      state.renderState = r.renderState;
      renderStagesTable();
    } catch (e) {
      setStatus("ERROR: " + e.message);
      RENDER_FOOTER.textContent = `${stage} failed: ${e.message}`;
    } finally {
      btn.disabled = false;
      btn.textContent = orig;
    }
  }

  async function saveRenderOptions() {
    try {
      const r = await fetchJson("/api/render-options", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(state.renderOptions),
      });
      state.renderOptions = r.options;
      // Re-fetch render-state because option hashes shift staleness.
      await refreshRenderState();
    } catch (e) {
      setStatus("ERROR: " + e.message);
    }
  }

  function syncOptionsControls() {
    OPT_CAPTIONS.checked = !!state.renderOptions.captions;
    document.querySelectorAll('input[name="audio-mode"]').forEach((el) => {
      el.checked = el.value === state.renderOptions.audioMode;
    });
    OPT_LOCAL_MODEL.value = state.renderOptions.localHeadModel;
    OPT_COMMERCIAL.value = state.renderOptions.commercialProvider;
  }

  // -------------------------------------------------------- bootstrap

  async function boot() {
    setStatus("loading…");
    const ts = await fetchJson("/api/timescale");
    state.canvasDims = { w: ts.canvasWidth, h: ts.canvasHeight };
    FOOTER_CANVAS.textContent = `${ts.canvasWidth} × ${ts.canvasHeight}`;

    const srcResp = await fetchJson("/api/sources");
    state.sources = srcResp.sources;
    PICKER.innerHTML = "";
    for (const s of state.sources) {
      if (s.kind === "screencast") continue;
      const o = document.createElement("option");
      o.value = s.path;
      o.textContent = s.label;
      PICKER.appendChild(o);
    }

    const track = await fetchJson("/api/avatar-track");
    state.track = track;
    state.selectedKf = state.track.keyframes.length > 0 ? 0 : -1;
    state.duration = Math.max(
      ...state.track.keyframes.map((k) => k.time),
      8
    ) + 2;

    const activeSrc = state.sources.find((s) => s.path === track.source_video);
    if (activeSrc) {
      PICKER.value = activeSrc.path;
      state.sourceDims = { w: activeSrc.width, h: activeSrc.height };
      FOOTER_SRC.textContent = `${activeSrc.width} × ${activeSrc.height}`;
    }

    SRC_VIDEO.src = fileUrl(track.source_video);
    SRC_VIDEO.addEventListener("loadedmetadata", () => {
      state.duration = Math.max(state.duration, SRC_VIDEO.duration + 1);
      rerenderEverything();
    });

    const comp = await fetchJson("/api/composite");
    COMP_VIDEO.src = fileUrl(comp.compositePath);
    COMP_VIDEO.addEventListener("loadedmetadata", () => rerenderEverything());

    PICKER.addEventListener("change", () => {
      state.track.source_video = PICKER.value;
      const s = state.sources.find((x) => x.path === PICKER.value);
      if (s) {
        state.sourceDims = { w: s.width, h: s.height };
        FOOTER_SRC.textContent = `${s.width} × ${s.height}`;
      }
      SRC_VIDEO.src = fileUrl(PICKER.value);
      saveTrack();
    });

    // Render manager — initial fetch + wire option controls.
    try {
      state.renderOptions = await fetchJson("/api/render-options");
    } catch (e) { /* in-memory script — fine */ }
    syncOptionsControls();
    await refreshRenderState();

    OPT_CAPTIONS.addEventListener("change", () => {
      state.renderOptions.captions = OPT_CAPTIONS.checked;
      saveRenderOptions();
    });
    document.querySelectorAll('input[name="audio-mode"]').forEach((el) => {
      el.addEventListener("change", () => {
        if (el.checked) {
          state.renderOptions.audioMode = el.value;
          saveRenderOptions();
        }
      });
    });
    OPT_LOCAL_MODEL.addEventListener("change", () => {
      state.renderOptions.localHeadModel = OPT_LOCAL_MODEL.value;
      saveRenderOptions();
    });
    OPT_COMMERCIAL.addEventListener("change", () => {
      state.renderOptions.commercialProvider = OPT_COMMERCIAL.value;
      saveRenderOptions();
    });

    RM_REFRESH.addEventListener("click", () => {
      state.bannerDismissed = false;
      refreshRenderState();
    });
    STALE_DISMISS.addEventListener("click", () => {
      state.bannerDismissed = true;
      STALE_BANNER.classList.add("hidden");
    });
    STALE_RENDER.addEventListener("click", () => {
      const btn = document.querySelector(
        '#render-stages-body button[data-stage="automation"]'
      );
      if (btn) renderStage("automation", btn);
    });

    window.addEventListener("resize", rerenderEverything);
    SRC_VIDEO.addEventListener("loadeddata", rerenderEverything);
    COMP_VIDEO.addEventListener("loadeddata", rerenderEverything);

    // Undo / redo keyboard shortcuts.  Standard mapping:
    //   macOS:   Cmd-Z        / Cmd-Shift-Z       (also Cmd-Y for redo)
    //   others:  Ctrl-Z       / Ctrl-Shift-Z       (also Ctrl-Y for redo)
    // Skip when a text input is focused so users can still revert
    // typed characters in numeric / text fields.
    window.addEventListener("keydown", (e) => {
      const tag = (e.target && e.target.tagName) || "";
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
      const mod = e.metaKey || e.ctrlKey;
      if (!mod) return;
      const k = e.key.toLowerCase();
      if (k === "z" && !e.shiftKey) {
        e.preventDefault();
        undo();
      } else if ((k === "z" && e.shiftKey) || k === "y") {
        e.preventDefault();
        redo();
      }
    });

    rerenderEverything();
    setStatus("ready");
  }

  boot().catch((e) => {
    setStatus("FATAL: " + e.message);
    console.error(e);
  });
})();
