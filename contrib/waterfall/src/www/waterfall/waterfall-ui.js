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

  function qs(action, iface, duration, channel, bandwidth) {
    let u = API + "?action=" + encodeURIComponent(action);
    if (iface) u += "&iface=" + encodeURIComponent(iface);
    if (duration != null && duration !== "") u += "&duration=" + encodeURIComponent(duration);
    if (channel != null && channel !== "") u += "&channel=" + encodeURIComponent(channel);
    if (bandwidth != null && bandwidth !== "") u += "&bandwidth=" + encodeURIComponent(bandwidth);
    return u;
  }

  async function api(action, iface, duration, channel, bandwidth) {
    const r = await fetch(qs(action, iface, duration, channel, bandwidth), { cache: "no-store", credentials: "same-origin" });
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
    const times = (cache && cache.times) || [];
    const meta = (cache && cache.meta) || {};
    const ctx = canvas.getContext("2d");
    const W = canvas.width;
    const H = canvas.height;
    const padL = 52, padR = 56, padT = 40, padB = 40;
    const plotW = W - padL - padR;
    const plotH = H - padT - padB;

    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, W, H);

    ctx.fillStyle = "#fff";
    ctx.font = "13px sans-serif";
    ctx.textAlign = "center";
    ctx.fillText("Waterfall History", W / 2, 14);

    if (!sweeps.length) {
      ctx.fillStyle = "#888";
      ctx.fillText("No cached capture — click Start (RF session)", W / 2, H / 2);
      return;
    }

    const rows = sweeps.length;
    const cols = sweeps[0].length || 1;
    const tStart = meta.t_start != null ? meta.t_start : 0;
    /* Prefer requested session length so a 60s run shows 0→60 even if samples end early. */
    let tStop;
    if (meta.requested_duration_sec != null && meta.requested_duration_sec > 0) {
      tStop = meta.requested_duration_sec;
    } else {
      tStop = meta.t_stop != null ? meta.t_stop : (meta.duration_sec || rows);
      if (times.length) {
        tStop = Math.max(tStop, times[times.length - 1] || 0);
      }
    }
    if (tStop <= tStart) tStop = tStart + 1;

    let maxV = 1;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < sweeps[r].length; c++) {
        if (sweeps[r][c] > maxV) maxV = sweeps[r][c];
      }
    }

    function rowAtTime(t) {
      if (!times.length) {
        const u = (t - tStart) / (tStop - tStart);
        return Math.min(rows - 1, Math.max(0, Math.floor(u * rows)));
      }
      /* nearest sample at or before t; clamp */
      let lo = 0, hi = times.length - 1;
      if (t <= times[0]) return 0;
      if (t >= times[hi]) return hi;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (times[mid] <= t) lo = mid;
        else hi = mid - 1;
      }
      return lo;
    }

    const img = ctx.createImageData(plotW, plotH);
    for (let y = 0; y < plotH; y++) {
      const t = tStart + ((y + 0.5) / plotH) * (tStop - tStart);
      const row = rowAtTime(t);
      const src = sweeps[row];
      for (let x = 0; x < plotW; x++) {
        const col = Math.min(cols - 1, Math.floor((x / plotW) * cols));
        const tv = (src[col] || 0) / maxV;
        const rgb = colorMap(tv);
        const i = (y * plotW + x) * 4;
        img.data[i] = rgb[0];
        img.data[i + 1] = rgb[1];
        img.data[i + 2] = rgb[2];
        img.data[i + 3] = 255;
      }
    }
    ctx.putImageData(img, padL, padT);

    const f0 = meta.f_start != null ? meta.f_start : 0;
    const f1 = meta.f_stop != null ? meta.f_stop : 0;
    const span = f1 > f0 ? f1 - f0 : 1;
    let axisCh = meta.axis_channels || [];
    if (!axisCh.length && cache && cache._scanChannels) axisCh = cache._scanChannels;
    let ticks = [];
    for (let i = 0; i < axisCh.length; i++) {
      const c = axisCh[i];
      if (c == null || c.frequency == null || c.number == null) continue;
      if (c.frequency < f0 || c.frequency > f1) continue;
      ticks.push(c);
    }
    const maxTicks = Math.max(4, Math.floor(plotW / 40));
    if (ticks.length > maxTicks) {
      const step = Math.ceil(ticks.length / maxTicks);
      const thinned = [];
      for (let i = 0; i < ticks.length; i += step) thinned.push(ticks[i]);
      ticks = thinned;
    }

    ctx.lineWidth = 1;
    if (ticks.length) {
      ctx.strokeStyle = "rgba(160,190,220,0.35)";
      ctx.fillStyle = "#9ab";
      ctx.font = "10px sans-serif";
      ctx.textAlign = "center";
      for (let i = 0; i < ticks.length; i++) {
        const x = padL + ((ticks[i].frequency - f0) / span) * plotW;
        ctx.beginPath();
        ctx.moveTo(x, padT);
        ctx.lineTo(x, padT + plotH);
        ctx.stroke();
        ctx.fillText(String(ticks[i].number), x, padT - 6);
      }
    } else {
      ctx.strokeStyle = "rgba(180,180,180,0.35)";
      for (let g = 0; g <= 6; g++) {
        const x = padL + (plotW * g) / 6;
        ctx.beginPath();
        ctx.moveTo(x, padT);
        ctx.lineTo(x, padT + plotH);
        ctx.stroke();
      }
    }
    ctx.strokeStyle = "rgba(180,180,180,0.35)";
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
    ctx.fillText("Time (s)", 0, 0);
    ctx.restore();

    ctx.textAlign = "right";
    ctx.fillText(tStart.toFixed(1), padL - 6, padT + 10);
    ctx.fillText(tStop.toFixed(1), padL - 6, padT + plotH);
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
    const channelSel = root.querySelector(".wf-channel");
    const bwSel = root.querySelector(".wf-bandwidth");
    let progressWrap = root.querySelector(".wf-progress");
    let progressBar = root.querySelector(".wf-progress-bar");
    let progressLabel = root.querySelector(".wf-progress-label");
    let pollTimer = null;
    let progressTimer = null;
    let alive = true;
    let selectedIface = null;
    let fillingRadios = false;
    let fillingScan = false;
    let lastScan = null;
    /* Local wall-clock estimate between status polls (browser-only). */
    let progressEndsAtMs = null;
    let progressDurationSec = null;
    let progressIface = null;

    function prefKey(kind) {
      return "waterfall." + kind + "." + (getIface() || "default");
    }

    function loadPref(kind, fallback) {
      try {
        const v = sessionStorage.getItem(prefKey(kind));
        return v != null && v !== "" ? v : fallback;
      } catch (_) {
        return fallback;
      }
    }

    function savePref(kind, value) {
      try {
        sessionStorage.setItem(prefKey(kind), String(value));
      } catch (_) {}
    }

    function getChannel() {
      if (channelSel && channelSel.value) return channelSel.value;
      return loadPref("channel", "");
    }

    function getBandwidth() {
      if (bwSel && bwSel.value) return bwSel.value;
      return loadPref("bandwidth", "");
    }

    function ensureProgressEls() {
      if (progressWrap && progressBar && progressLabel) return;
      if (!canvas || !canvas.parentNode) return;
      progressWrap = document.createElement("div");
      progressWrap.className = "wf-progress";
      progressWrap.hidden = true;
      progressWrap.style.cssText = "margin:6px 0 0";
      progressWrap.innerHTML =
        '<div class="wf-progress-track" style="height:8px;background:#222;border-radius:4px;overflow:hidden">' +
        '<div class="wf-progress-bar" style="height:100%;width:0%;background:#3a7abd;transition:width 0.15s linear"></div></div>' +
        '<div class="wf-progress-label" style="margin-top:4px;font-size:0.8em;opacity:0.85"></div>';
      canvas.parentNode.insertBefore(progressWrap, canvas.nextSibling);
      progressBar = progressWrap.querySelector(".wf-progress-bar");
      progressLabel = progressWrap.querySelector(".wf-progress-label");
    }

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

    function stopProgressTick() {
      if (progressTimer) {
        clearInterval(progressTimer);
        progressTimer = null;
      }
    }

    function hideProgress() {
      stopProgressTick();
      progressEndsAtMs = null;
      progressDurationSec = null;
      progressIface = null;
      ensureProgressEls();
      if (progressWrap) progressWrap.hidden = true;
      if (progressBar) progressBar.style.width = "0%";
      if (progressLabel) progressLabel.textContent = "";
    }

    function paintProgress() {
      ensureProgressEls();
      if (!progressWrap || !progressBar || !progressLabel) return;
      if (progressEndsAtMs == null || !progressDurationSec || progressDurationSec <= 0) {
        hideProgress();
        return;
      }
      const leftSec = Math.max(0, (progressEndsAtMs - Date.now()) / 1000);
      const done = Math.min(1, Math.max(0, 1 - leftSec / progressDurationSec));
      progressWrap.hidden = false;
      progressBar.style.width = (done * 100).toFixed(1) + "%";
      const leftRound = Math.ceil(leftSec);
      progressLabel.textContent =
        (progressIface || "?") + " · " + Math.round(done * 100) + "% · ~" + leftRound + "s left";
    }

    function syncProgressFromStatus(status) {
      if (!status || !status.running) {
        hideProgress();
        return;
      }
      const sess = status.session || {};
      const dur = sess.duration_sec || status.remaining_sec || getDuration();
      let left = status.remaining_sec;
      if (left == null && sess.ends_at != null && status.server_now != null) {
        left = Math.max(0, sess.ends_at - status.server_now);
      }
      if (left == null && sess.ends_at != null) {
        left = Math.max(0, sess.ends_at - Math.floor(Date.now() / 1000));
      }
      if (left == null) left = dur;
      progressDurationSec = dur > 0 ? dur : 30;
      progressEndsAtMs = Date.now() + left * 1000;
      progressIface = sess.iface || getIface() || "?";
      paintProgress();
      if (!progressTimer) {
        progressTimer = setInterval(function () {
          if (!alive) {
            stopProgressTick();
            return;
          }
          paintProgress();
        }, 250);
      }
    }

    function applyRunningUi(status) {
      const running = !!(status && status.running);
      if (startBtn) {
        startBtn.disabled = running;
        startBtn.title = running
          ? ("Scan already in progress on " + ((status.session && status.session.iface) || "?") +
            (status.remaining_sec != null ? (" (~" + status.remaining_sec + "s left)") : ""))
          : "";
      }
      if (stopBtn) stopBtn.disabled = !running;
      if (durSel) durSel.disabled = running;
      if (radioSel) radioSel.disabled = running;
      if (channelSel) channelSel.disabled = running;
      if (bwSel) bwSel.disabled = running;
      if (running) syncProgressFromStatus(status);
      else hideProgress();
    }

    function channelsForBw(scan, bw) {
      if (!scan) return [];
      if (bw === "all") {
        const bws = scan.bandwidths || [];
        const key = bws.indexOf(20) >= 0 ? "20" : (bws[0] != null ? String(bws[0]) : "10");
        const by = scan.channels_by_bw || {};
        return by[key] || scan.channels || [];
      }
      const by = scan.channels_by_bw || {};
      return by[String(bw)] || scan.channels || [];
    }

    function channelInList(list, ch) {
      if (ch == null || ch === "" || ch === "all") return false;
      const s = String(ch);
      for (let i = 0; i < list.length; i++) {
        if (String(list[i].number) === s) return true;
      }
      return false;
    }

    function pickChannel(list, preferred, curCh) {
      if (channelInList(list, preferred)) return String(preferred);
      if (channelInList(list, curCh)) return String(curCh);
      if (list.length) return String(list[0].number);
      return curCh != null && curCh !== "" ? String(curCh) : "";
    }

    function rememberNonAll(ch, bw) {
      if (ch && ch !== "all") savePref("lastChannel", ch);
      if (bw && bw !== "all") savePref("lastBandwidth", bw);
    }

    function fillScanControls(status, opts) {
      opts = opts || {};
      if (!channelSel && !bwSel) return;
      const scan = (status && status.scan) || lastScan;
      if (!scan) return;
      lastScan = scan;
      fillingScan = true;
      const bws = scan.bandwidths || [5, 10, 20, 40, 80];
      const curBw = scan.current_bandwidth != null ? String(scan.current_bandwidth) : (bws[0] != null ? String(bws[0]) : "10");
      const curCh = scan.current_channel != null ? String(scan.current_channel) : "";
      let wantBw = opts.bandwidth != null ? String(opts.bandwidth) : loadPref("bandwidth", curBw);
      let wantCh = opts.channel != null ? String(opts.channel) : loadPref("channel", curCh || "all");
      if (wantBw === "all") wantCh = "all";
      if (wantCh === "all") wantBw = "all";

      if (bwSel) {
        bwSel.innerHTML = "";
        const allBw = document.createElement("option");
        allBw.value = "all";
        allBw.textContent = "ALL";
        bwSel.appendChild(allBw);
        for (let i = 0; i < bws.length; i++) {
          const opt = document.createElement("option");
          opt.value = String(bws[i]);
          opt.textContent = bws[i] + " MHz";
          bwSel.appendChild(opt);
        }
        bwSel.value = wantBw;
        if (bwSel.value !== wantBw) bwSel.value = curBw;
        wantBw = bwSel.value;
      }

      if (channelSel) {
        const list = channelsForBw(scan, wantBw === "all" ? "all" : wantBw);
        channelSel.innerHTML = "";
        const allCh = document.createElement("option");
        allCh.value = "all";
        allCh.textContent = "ALL (full band)";
        channelSel.appendChild(allCh);
        for (let i = 0; i < list.length; i++) {
          const c = list[i];
          const opt = document.createElement("option");
          opt.value = String(c.number);
          let label = c.label || (c.number + " (" + c.frequency + ")");
          if (curCh && String(c.number) === curCh) label += " · radio";
          opt.textContent = label;
          channelSel.appendChild(opt);
        }
        channelSel.value = wantCh;
        if (channelSel.value !== wantCh) {
          channelSel.value = channelInList(list, curCh) ? curCh : (list.length ? String(list[0].number) : "all");
        }
        wantCh = channelSel.value;
      }

      if (wantBw === "all" && channelSel) channelSel.value = "all";
      if (wantCh === "all" && bwSel) bwSel.value = "all";
      const outBw = bwSel ? bwSel.value : wantBw;
      const outCh = channelSel ? channelSel.value : wantCh;
      savePref("bandwidth", outBw);
      savePref("channel", outCh);
      rememberNonAll(outCh, outBw);
      fillingScan = false;
    }

    function runningMessage(status) {
      const sess = (status && status.session) || {};
      const iface = sess.iface || "?";
      let left = status.remaining_sec;
      if (left == null && sess.ends_at != null && status.server_now != null) {
        left = Math.max(0, sess.ends_at - status.server_now);
      }
      if (left == null && sess.ends_at != null) {
        left = Math.max(0, sess.ends_at - Math.floor(Date.now() / 1000));
      }
      const leftTxt = left != null ? ("~" + left + "s left") : "time unknown";
      return "A waterfall scan is already in progress on " + iface +
        " · est. " + leftTxt + " · RF disrupted until it finishes (or Stop)";
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
      applyRunningUi(status);
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
      fillingRadios = false;
      applyRunningUi(status);
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
        fillScanControls(s);
        applyRunningUi(s);
        if (s.running) {
          setStatus(runningMessage(s));
          try { await loadCache(); } catch (_) {}
        } else {
          stopPoll();
          applyRunningUi(s);
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
      pollTimer = setInterval(refreshStatus, 1000);
    }

    if (radioSel) {
      radioSel.addEventListener("change", () => {
        if (fillingRadios) return;
        selectedIface = radioSel.value || null;
        api("status", selectedIface).then((s) => {
          fillScanControls(s);
          return loadCache();
        }).catch((e) => setStatus(String(e.message || e)));
      });
    }

    if (bwSel) {
      bwSel.addEventListener("change", () => {
        if (fillingScan) return;
        const scan = lastScan;
        const curBw = scan && scan.current_bandwidth != null ? String(scan.current_bandwidth) : "10";
        const curCh = scan && scan.current_channel != null ? String(scan.current_channel) : "";
        const prevBw = loadPref("bandwidth", "");
        const prevCh = channelSel ? channelSel.value : loadPref("channel", "");
        let bw = bwSel.value;
        let ch = prevCh;
        if (bw === "all") {
          rememberNonAll(prevCh, prevBw);
          ch = "all";
        } else if (prevBw === "all" || ch === "all") {
          const list = channelsForBw(scan, bw);
          ch = pickChannel(list, loadPref("lastChannel", ""), curCh);
        } else {
          const list = channelsForBw(scan, bw);
          ch = pickChannel(list, ch, curCh);
        }
        savePref("bandwidth", bw);
        savePref("channel", ch);
        rememberNonAll(ch, bw);
        fillScanControls(scan ? { scan: scan } : null, { bandwidth: bw, channel: ch });
      });
    }

    if (channelSel) {
      channelSel.addEventListener("change", () => {
        if (fillingScan) return;
        const scan = lastScan;
        const curBw = scan && scan.current_bandwidth != null ? String(scan.current_bandwidth) : "10";
        const prevBw = bwSel ? bwSel.value : loadPref("bandwidth", "");
        const prevCh = loadPref("channel", "");
        let ch = channelSel.value;
        let bw = prevBw;
        if (ch === "all") {
          rememberNonAll(prevCh, prevBw);
          bw = "all";
        } else if (prevCh === "all" || bw === "all") {
          /* Leave ALL via Channel → BW resets to radio configured BW. */
          bw = curBw;
        }
        savePref("channel", ch);
        savePref("bandwidth", bw);
        rememberNonAll(ch, bw);
        fillScanControls(scan ? { scan: scan } : null, { bandwidth: bw, channel: ch });
      });
    }

    if (startBtn) {
      startBtn.addEventListener("click", async () => {
        try {
          if (startBtn.disabled) return;
          const iface = getIface();
          const dur = getDuration();
          const ch = getChannel() || undefined;
          const bw = getBandwidth() || undefined;
          if (!iface) {
            setStatus("Select a radio with spectral support first");
            return;
          }
          /* Re-check before start in case another UI started a scan. */
          const cur = await api("status", iface);
          if (cur.running) {
            applyRunningUi(cur);
            setStatus(runningMessage(cur));
            startPoll();
            return;
          }
          setStatus("Starting " + dur + "s session on " + iface +
            " (ch " + (ch || "current") + " / " + (bw || "current") + " MHz)…");
          startBtn.disabled = true;
          const r = await api("start", iface, dur, ch, bw);
          if (!r.ok) {
            const st = await api("status", iface).catch(() => null);
            if (st && st.running) {
              applyRunningUi(st);
              setStatus(runningMessage(st));
              startPoll();
            } else {
              applyRunningUi({ running: false });
              setStatus(r.error || "Start failed");
            }
            return;
          }
          const started = {
            running: true,
            remaining_sec: dur,
            session: {
              iface: r.iface || iface,
              ends_at: r.ends_at,
              duration_sec: r.duration_sec || dur
            }
          };
          applyRunningUi(started);
          setStatus(runningMessage(started));
          startPoll();
        } catch (e) {
          applyRunningUi({ running: false });
          setStatus(String(e.message || e));
        }
      });
    }
    if (stopBtn) {
      stopBtn.addEventListener("click", async () => {
        try {
          await api("stop", getIface());
          stopPoll();
          applyRunningUi({ running: false });
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
        hideProgress();
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
      hideProgress();
    }

    resize();
    ensureProgressEls();
    hideProgress();
    api("status").then(async (s) => {
      fillRadios(s);
      fillDurations(s);
      fillScanControls(s);
      applyRunningUi(s);
      if (s.running) {
        setStatus(runningMessage(s));
        startPoll();
        try { await loadCache(); } catch (_) {}
      } else {
        await loadCache();
      }
    }).catch((e) => setStatus(String(e.message || e)));

    root._wfDestroy = destroy;
    return { destroy: destroy };
  }

  global.WaterfallUI = { mount: mount, drawHeatmap: drawHeatmap };
})(window);
