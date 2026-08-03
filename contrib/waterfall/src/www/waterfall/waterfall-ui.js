/**
 * Shared Waterfall heatmap UI (Tools modal + /a/waterfall page).
 * Expects global WaterfallUI.mount(rootEl, options).
 */
(function (global) {
  const API = "/a/waterfall/e/api";

  function colorMap(t) {
    t = Math.max(0, Math.min(1, t));
    const stops = [
      [0.0, 0, 0, 80],
      [0.2, 0, 60, 200],
      [0.4, 0, 180, 120],
      [0.6, 180, 220, 0],
      [0.8, 255, 140, 0],
      [1.0, 255, 30, 30]
    ];
    for (let i = 0; i < stops.length - 1; i++) {
      const a = stops[i], b = stops[i + 1];
      if (t >= a[0] && t <= b[0]) {
        const u = (t - a[0]) / (b[0] - a[0] || 1);
        return [
          (a[1] + (b[1] - a[1]) * u) | 0,
          (a[2] + (b[2] - a[2]) * u) | 0,
          (a[3] + (b[3] - a[3]) * u) | 0
        ];
      }
    }
    return [255, 30, 30];
  }

  function qs(action, iface, duration) {
    let u = API + "?action=" + encodeURIComponent(action);
    if (iface) u += "&iface=" + encodeURIComponent(iface);
    if (duration != null && duration !== "") u += "&duration=" + encodeURIComponent(duration);
    return u;
  }

  async function api(action, iface, duration) {
    const r = await fetch(qs(action, iface, duration), { cache: "no-store", credentials: "same-origin" });
    const text = await r.text();
    let j = null;
    try {
      j = JSON.parse(text);
    } catch (e) {
      const snippet = (text || "").replace(/\s+/g, " ").slice(0, 120);
      throw new Error("Bad API response (" + r.status + "): " + (snippet || e.message));
    }
    if (r.status === 401) {
      throw new Error((j && j.error) || "Admin authentication required");
    }
    if (!r.ok && j && j.error) {
      throw new Error(j.error);
    }
    return j;
  }

  function durationLabel(sec) {
    if (sec < 60) return sec + "s";
    if (sec === 60) return "60s / 1m";
    if (sec % 60 === 0) return (sec / 60) + "m";
    return sec + "s";
  }

  function radioLabel(r) {
    const bits = [r.iface, r.band || "", r.chipset || "", "mode=" + (r.mode || "?")];
    if (r.capture_mode === "fft" || r.fft_available) {
      bits.push(r.chipset === "ath10k" ? "FFT+survey" : "spectral FFT");
    } else if (r.capture_mode === "survey" || r.survey_available) {
      bits.push("survey");
    } else {
      bits.push("no capture");
    }
    return bits.filter(Boolean).join(" · ");
  }

  function drawHeatmap(canvas, cache) {
    const sweeps = (cache && cache.sweeps) || [];
    const meta = (cache && cache.meta) || {};
    const ctx = canvas.getContext("2d");
    const W = canvas.width;
    const H = canvas.height;
    const padL = 48, padR = 56, padT = 28, padB = 40;
    const plotW = W - padL - padR;
    const plotH = H - padT - padB;

    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, W, H);

    ctx.fillStyle = "#fff";
    ctx.font = "13px sans-serif";
    ctx.textAlign = "center";
    ctx.fillText("Waterfall History", W / 2, 18);

    if (!sweeps.length) {
      ctx.fillStyle = "#888";
      ctx.fillText("No cached capture — click Start (30s RF session)", W / 2, H / 2);
      return;
    }

    const rows = sweeps.length;
    const cols = sweeps[0].length || 1;
    let maxV = 1;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < sweeps[r].length; c++) {
        if (sweeps[r][c] > maxV) maxV = sweeps[r][c];
      }
    }

    const img = ctx.createImageData(plotW, plotH);
    for (let y = 0; y < plotH; y++) {
      const row = Math.min(rows - 1, Math.floor((y / plotH) * rows));
      const src = sweeps[row];
      for (let x = 0; x < plotW; x++) {
        const col = Math.min(cols - 1, Math.floor((x / plotW) * cols));
        const t = (src[col] || 0) / maxV;
        const rgb = colorMap(t);
        const i = (y * plotW + x) * 4;
        img.data[i] = rgb[0];
        img.data[i + 1] = rgb[1];
        img.data[i + 2] = rgb[2];
        img.data[i + 3] = 255;
      }
    }
    ctx.putImageData(img, padL, padT);

    ctx.strokeStyle = "rgba(180,180,180,0.35)";
    ctx.lineWidth = 1;
    for (let g = 0; g <= 6; g++) {
      const x = padL + (plotW * g) / 6;
      ctx.beginPath();
      ctx.moveTo(x, padT);
      ctx.lineTo(x, padT + plotH);
      ctx.stroke();
    }
    for (let g = 0; g <= 6; g++) {
      const y = padT + (plotH * g) / 6;
      ctx.beginPath();
      ctx.moveTo(padL, y);
      ctx.lineTo(padL + plotW, y);
      ctx.stroke();
    }

    for (let y = 0; y < plotH; y++) {
      const t = 1 - y / plotH;
      const rgb = colorMap(t);
      ctx.fillStyle = "rgb(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + ")";
      ctx.fillRect(W - padR + 12, padT + y, 14, 1);
    }

    const f0 = meta.f_start != null ? meta.f_start : 0;
    const f1 = meta.f_stop != null ? meta.f_stop : 0;
    ctx.fillStyle = "#ccc";
    ctx.font = "11px sans-serif";
    ctx.textAlign = "left";
    ctx.fillText("Start: " + Math.round(f0) + " MHz", padL, H - 12);
    ctx.textAlign = "right";
    ctx.fillText("Stop: " + Math.round(f1) + " MHz", padL + plotW, H - 12);
    ctx.textAlign = "center";
    ctx.fillText("Frequency", padL + plotW / 2, H - 12);

    ctx.save();
    ctx.translate(14, padT + plotH / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.fillText("Sweep", 0, 0);
    ctx.restore();

    ctx.textAlign = "right";
    ctx.fillText("0", padL - 6, padT + plotH);
    ctx.fillText(String(-rows), padL - 6, padT + 10);
  }

  function mount(root, options) {
    options = options || {};
    const isModal = !!options.modal;
    const canvas = root.querySelector(".wf-canvas");
    const statusEl = root.querySelector(".wf-status");
    const startBtn = root.querySelector(".wf-start");
    const stopBtn = root.querySelector(".wf-stop");
    const closeBtn = root.querySelector(".wf-close");
    const radioSel = root.querySelector(".wf-radio");
    const durSel = root.querySelector(".wf-duration");
    let pollTimer = null;
    let alive = true;
    let selectedIface = null;
    let fillingRadios = false;

    function setStatus(t) {
      if (statusEl) statusEl.textContent = t || "";
    }

    function getIface() {
      if (radioSel && radioSel.value) return radioSel.value;
      return selectedIface;
    }

    function getDuration() {
      if (durSel && durSel.value) return parseInt(durSel.value, 10) || 30;
      return 30;
    }

    function fillDurations(status) {
      if (!durSel) return;
      const list = (status && status.durations) || [5, 10, 15, 30, 60, 300, 600];
      const def = (status && status.default_duration) || 30;
      const prev = durSel.value;
      durSel.innerHTML = "";
      for (let i = 0; i < list.length; i++) {
        const sec = list[i];
        const opt = document.createElement("option");
        opt.value = String(sec);
        opt.textContent = durationLabel(sec);
        if (sec === def) opt.selected = true;
        durSel.appendChild(opt);
      }
      if (prev) durSel.value = prev;
      else durSel.value = String(def);
      durSel.disabled = !!(status && status.running);
    }

    function fillRadios(status) {
      if (!radioSel) return;
      fillingRadios = true;
      const radios = (status && status.radios) || [];
      const prefer = selectedIface ||
        (status && (status.selected_iface || (status.capability && status.capability.iface))) || "";
      radioSel.innerHTML = "";
      let firstSelectable = null;
      for (let i = 0; i < radios.length; i++) {
        const r = radios[i];
        const opt = document.createElement("option");
        opt.value = r.iface;
        opt.textContent = radioLabel(r);
        opt.disabled = !r.selectable;
        if (r.selectable && !firstSelectable) firstSelectable = r.iface;
        radioSel.appendChild(opt);
      }
      if (!radios.length) {
        const opt = document.createElement("option");
        opt.value = "";
        opt.textContent = "No RF radios found";
        radioSel.appendChild(opt);
      }
      const want = prefer || firstSelectable || "";
      if (want) radioSel.value = want;
      selectedIface = radioSel.value || null;
      radioSel.disabled = !!status.running;
      fillingRadios = false;
    }

    function resize() {
      if (!canvas) return;
      const w = Math.max(480, root.clientWidth - 24);
      canvas.width = w;
      canvas.height = isModal ? 320 : Math.min(520, Math.max(360, window.innerHeight - 220));
    }

    async function loadCache() {
      const iface = getIface();
      const c = await api("cache", iface);
      resize();
      drawHeatmap(canvas, c);
      if (c.have_cache && c.meta) {
        setStatus("Cached (" + (c.meta.iface || iface || "?") + "): " + c.meta.sweep_count +
          " sweeps · " + Math.round(c.meta.f_start) + "–" + Math.round(c.meta.f_stop) + " MHz · " +
          (c.meta.chipset || "") +
          (c.meta.requested_duration_sec ? (" · " + c.meta.requested_duration_sec + "s run") : "") +
          " · ended " + (c.meta.ended_at || ""));
      } else {
        setStatus("No cache for " + (iface || "radio") + ". Choose duration and Start (RF disrupted).");
      }
      return c;
    }

    async function refreshStatus() {
      if (!alive || !document.contains(root)) {
        stopPoll();
        return;
      }
      try {
        const s = await api("status", getIface());
        fillRadios(s);
        fillDurations(s);
        if (s.running) {
          const left = Math.max(0, (s.session.ends_at || 0) - Math.floor(Date.now() / 1000));
          setStatus("Capturing on " + (s.session.iface || getIface() || "?") +
            "… RF disrupted · ~" + left + "s left · reconnect after to view cache");
          try { await loadCache(); } catch (_) {}
        } else {
          stopPoll();
          await loadCache();
          setStatus((statusEl.textContent || "") + " · session idle (RF restored)");
        }
      } catch (e) {
        setStatus(String(e.message || e));
      }
    }

    function stopPoll() {
      if (pollTimer) {
        clearInterval(pollTimer);
        pollTimer = null;
      }
    }

    function startPoll() {
      stopPoll();
      pollTimer = setInterval(refreshStatus, 2000);
    }

    if (radioSel) {
      radioSel.addEventListener("change", () => {
        if (fillingRadios) return;
        selectedIface = radioSel.value || null;
        loadCache().catch((e) => setStatus(String(e.message || e)));
      });
    }

    if (startBtn) {
      startBtn.addEventListener("click", async () => {
        try {
          const iface = getIface();
          const dur = getDuration();
          if (!iface) {
            setStatus("Select a radio with spectral support first");
            return;
          }
          setStatus("Starting " + dur + "s session on " + iface + "…");
          const r = await api("start", iface, dur);
          if (!r.ok) {
            setStatus(r.error || "Start failed");
            return;
          }
          setStatus(r.warning || ("Capturing on " + iface + "…"));
          startPoll();
        } catch (e) {
          setStatus(String(e.message || e));
        }
      });
    }
    if (stopBtn) {
      stopBtn.addEventListener("click", async () => {
        try {
          await api("stop", getIface());
          stopPoll();
          await loadCache();
          setStatus("Stopped early · RF restored · showing cache for " + (getIface() || "radio"));
        } catch (e) {
          setStatus(String(e.message || e));
        }
      });
    }
    if (closeBtn) {
      closeBtn.addEventListener("click", () => {
        alive = false;
        stopPoll();
        /* Must call dialog.close() — clearing innerHTML alone leaves [open]
         * and the grey ::backdrop (see #ctrl-modal[open]:empty in admin.css). */
        const modal = document.getElementById("ctrl-modal");
        if (modal && typeof modal.close === "function") {
          modal.close();
        } else if (modal) {
          modal.innerHTML = "";
        }
      });
    }

    function destroy() {
      alive = false;
      stopPoll();
    }

    resize();
    api("status").then(async (s) => {
      fillRadios(s);
      fillDurations(s);
      await loadCache();
      if (s.running) startPoll();
    }).catch((e) => setStatus(String(e.message || e)));

    root._wfDestroy = destroy;
    return { destroy: destroy };
  }

  global.WaterfallUI = { mount: mount, drawHeatmap: drawHeatmap };
})(window);
