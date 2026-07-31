(function () {
  "use strict";

  const statusEl = document.getElementById("status");
  const reconnectBtn = document.getElementById("btn-reconnect");
  const disconnectBtn = document.getElementById("btn-disconnect");
  const term = new Terminal({
    cursorBlink: true,
    // ash without a PTY emits bare LF; convert to CRLF so lines advance correctly.
    convertEol: true,
    fontSize: 14,
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
    theme: {
      background: "#0d1117",
      foreground: "#e6edf3",
      cursor: "#58a6ff",
      selectionBackground: "#264f78"
    }
  });
  const fitAddon = new FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  term.open(document.getElementById("terminal"));
  fitAddon.fit();

  let sid = null;
  let pollTimer = null;
  let pingTimer = null;
  let starting = false;

  function setStatus(text) {
    if (statusEl) {
      statusEl.textContent = text;
    }
  }

  function b64encode(str) {
    return btoa(unescape(encodeURIComponent(str)));
  }

  function b64decode(str) {
    try {
      return decodeURIComponent(escape(atob(str)));
    } catch (e) {
      try {
        return atob(str);
      } catch (e2) {
        return "";
      }
    }
  }

  async function api(op, opts) {
    opts = opts || {};
    const params = new URLSearchParams();
    params.set("op", op);
    if (opts.sid) {
      params.set("sid", opts.sid);
    }
    let url = "/cgi-bin/terminal-api?" + params.toString();
    const init = {
      method: opts.method || "GET",
      credentials: "same-origin",
      cache: "no-store"
    };
    if (opts.body != null) {
      init.method = "POST";
      init.headers = { "Content-Type": "text/plain; charset=utf-8" };
      init.body = opts.body;
    }
    if (opts.dataB64) {
      params.set("data", opts.dataB64);
      url = "/cgi-bin/terminal-api?" + params.toString();
      init.method = "POST";
    }
    const res = await fetch(url, init);
    let json = null;
    try {
      json = await res.json();
    } catch (e) {
      json = { error: "bad_json", status: res.status };
    }
    if (!res.ok) {
      const err = new Error((json && json.message) || (json && json.error) || ("HTTP " + res.status));
      err.status = res.status;
      err.payload = json;
      throw err;
    }
    return json;
  }

  function stopPolling() {
    if (pollTimer) {
      clearTimeout(pollTimer);
      pollTimer = null;
    }
    if (pingTimer) {
      clearInterval(pingTimer);
      pingTimer = null;
    }
  }

  async function pollOnce() {
    if (!sid) {
      return;
    }
    try {
      const r = await api("read", { sid: sid });
      if (r.data) {
        term.write(b64decode(r.data));
      }
      pollTimer = setTimeout(pollOnce, 120);
    } catch (e) {
      if (e.status === 410) {
        sid = null;
        stopPolling();
        setConnectedUi(false);
        setStatus("session ended");
      } else {
        setStatus("read error: " + e.message);
        pollTimer = setTimeout(pollOnce, 1000);
      }
    }
  }

  function setConnectedUi(connected) {
    if (disconnectBtn) {
      disconnectBtn.disabled = !connected;
    }
  }

  async function disconnectSession() {
    stopPolling();
    const old = sid;
    sid = null;
    setConnectedUi(false);
    setStatus("disconnecting…");
    if (old) {
      try {
        await api("stop", { sid: old, method: "POST" });
      } catch (e) { /* ignore */ }
    }
    // Apps-bar launches this in a new tab; return to the node admin UI.
    location.replace("/a/status");
  }

  async function startSession() {
    if (starting) {
      return;
    }
    starting = true;
    stopPolling();
    setStatus("starting…");
    try {
      if (sid) {
        try {
          await api("stop", { sid: sid, method: "POST" });
        } catch (e) { /* ignore */ }
        sid = null;
      }
      term.reset();
      const r = await api("start", { method: "POST" });
      sid = r.sid;
      setStatus("connected (" + sid + ")");
      setConnectedUi(true);
      pollOnce();
      pingTimer = setInterval(function () {
        if (sid) {
          api("ping", { sid: sid, method: "POST" }).catch(function () {});
        }
      }, 15000);
    } catch (e) {
      sid = null;
      setConnectedUi(false);
      setStatus("failed: " + e.message);
    } finally {
      starting = false;
    }
  }

  term.onData(function (data) {
    if (!sid) {
      return;
    }
    // POST raw keystrokes in the body (avoids query-length limits on paste).
    api("write", { sid: sid, method: "POST", body: data }).catch(function (e) {
      setStatus("write error: " + e.message);
    });
  });

  window.addEventListener("resize", function () {
    fitAddon.fit();
  });

  window.addEventListener("beforeunload", function () {
    if (!sid) {
      return;
    }
    const url = "/cgi-bin/terminal-api?op=stop&sid=" + encodeURIComponent(sid);
    if (navigator.sendBeacon) {
      navigator.sendBeacon(url);
    }
  });

  if (reconnectBtn) {
    reconnectBtn.addEventListener("click", startSession);
  }
  if (disconnectBtn) {
    disconnectBtn.addEventListener("click", disconnectSession);
  }

  setConnectedUi(false);
  startSession();
})();
