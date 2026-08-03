/**
 * Waterfall package library.
 * RF spectrum probe/capture for 5 GHz AREDN radios (ath9k first; ath10k experimental).
 * Focus: Rocket M5, PowerBeam 500 / 500 AC, MikroTik hAP ac lite (5 GHz).
 *
 * Spectral scan disrupts RF. Capture sessions are bounded (default 30s), always
 * restore spectral_scan_ctl to disable, and cache parsed sweeps in /tmp (RAM).
 */

import * as fs from "fs";
import * as nl80211 from "nl80211";
import * as radios from "aredn.radios";
import * as hardware from "aredn.hardware";

const FFT_OUT = "/tmp/waterfall-fft.bin";
const CACHE_JSON = "/tmp/waterfall-cache.json";
const SESSION_JSON = "/tmp/waterfall-session.json";
const SESSION_PID = "/tmp/waterfall-session.pid";
const SESSION_STOP = "/tmp/waterfall-session.stop";
const DBG_BASE = "/sys/kernel/debug/ieee80211";

const ATH_FFT_SAMPLE_HT20 = 1;
const ATH_FFT_SAMPLE_HT20_40 = 2;
const ATH_FFT_SAMPLE_ATH10K = 3;

const SESSION_DEFAULT_SEC = 30;
const MAX_SWEEPS = 60;
const TARGET_BINS = 64;

export function packageVersion()
{
    return "0.2.3-r0";
};

function isMeshMode(mode)
{
    return mode === radios.RADIO_MESH || mode === radios.RADIO_MESHSTA ||
        mode === radios.RADIO_MESHPTP || mode === radios.RADIO_MESHPTMP;
}

function chipsetForPhy(phy)
{
    if (!phy) {
        return "unknown";
    }
    if (fs.access(`${DBG_BASE}/${phy}/ath9k`)) {
        return "ath9k";
    }
    if (fs.access(`${DBG_BASE}/${phy}/ath10k`)) {
        return "ath10k";
    }
    if (fs.access(`${DBG_BASE}/${phy}/mt76`)) {
        return "mt76";
    }
    if (fs.access(`${DBG_BASE}/${phy}/morse`)) {
        return "morse";
    }
    return "unknown";
}

function spectralPaths(phy, chipset)
{
    if (chipset !== "ath9k" && chipset !== "ath10k") {
        return null;
    }
    const dir = `${DBG_BASE}/${phy}/${chipset}`;
    return {
        dir: dir,
        ctl: `${dir}/spectral_scan_ctl`,
        relay: `${dir}/spectral_scan0`,
        count: `${dir}/spectral_count`,
        bins: `${dir}/spectral_bins`
    };
}

function focusNote(chipset, fftAvailable, board)
{
    const bid = lc(board || "");
    const hapLite = match(bid, /952ui-5ac2nd|hap ac lite/);

    if (chipset === "ath9k" && fftAvailable) {
        return "ath9k spectral FFT available (Rocket M5 / PowerBeam M5 class; also hAP ac lite 2.4 GHz radio). Current-channel capture supported. Prefer 5 GHz iface when present.";
    }
    if (chipset === "ath10k" && fftAvailable) {
        if (hapLite) {
            return "ath10k spectral FFT on hAP ac lite 5 GHz (QCA9887). Experimental at AREDN mesh bandwidths; this is the preferred waterfall radio on this board.";
        }
        return "ath10k spectral FFT present (PowerBeam 500 AC / similar). Experimental at AREDN mesh bandwidths; QCA988x scan caveats may apply. Some Ubiquiti AC boards also have an uncalibrated SoC spectrum radio.";
    }
    if (chipset === "ath10k") {
        return "ath10k radio without spectral debugfs nodes (ATH_SPECTRAL may be unavailable on this build/driver).";
    }
    if (chipset === "unknown") {
        return "Chipset not recognized for spectral capture.";
    }
    return `Chipset ${chipset} has no waterfall FFT path in this package yet.`;
}

function radioHasFft(r)
{
    if (!r?.phy) {
        return false;
    }
    const paths = spectralPaths(r.phy, r.chipset);
    if (!paths) {
        return false;
    }
    return !!fs.access(paths.ctl) && !!fs.access(paths.relay);
}

function writeCtl(path, value)
{
    const f = fs.open(path, "w");
    if (!f) {
        return false;
    }
    f.write(`${value}\n`);
    f.close();
    return true;
}

function nowSec()
{
    return int(clock()[0]);
}

function be16(buf, off)
{
    return (ord(buf, off) << 8) | ord(buf, off + 1);
}

function be16s(buf, off)
{
    let v = be16(buf, off);
    if (v >= 32768) {
        v -= 65536;
    }
    return v;
}

function downsampleBins(bins, target)
{
    const n = length(bins);
    if (n <= 0) {
        return [];
    }
    if (n <= target) {
        return bins;
    }
    const out = [];
    for (let i = 0; i < target; i++) {
        const a = int(i * n / target);
        let b = int((i + 1) * n / target);
        if (b <= a) {
            b = a + 1;
        }
        let mx = 0;
        for (let j = a; j < b && j < n; j++) {
            if (bins[j] > mx) {
                mx = bins[j];
            }
        }
        push(out, mx);
    }
    return out;
}

/**
 * Parse spectral TLV binary into sample objects { type, f_start, f_stop, noise, bins }.
 */
export function parseFftTlvs(buf, maxSamples)
{
    const samples = [];
    if (!buf || length(buf) < 3) {
        return samples;
    }
    if (maxSamples == null || maxSamples <= 0) {
        maxSamples = 32;
    }
    const n = length(buf);
    let pos = 0;
    while (pos + 3 <= n && length(samples) < maxSamples) {
        const typ = ord(buf, pos);
        const plen = be16(buf, pos + 1);
        const total = 3 + plen;
        if (plen < 1 || pos + total > n) {
            break;
        }
        const base = pos + 3;

        if (typ === ATH_FFT_SAMPLE_ATH10K) {
            const hdr = 26;
            if (plen < hdr + 16) {
                pos += total;
                continue;
            }
            const bw = ord(buf, base);
            const freq1 = be16(buf, base + 1);
            const noise = be16s(buf, base + 5);
            if (noise === 0) {
                pos += total;
                continue;
            }
            const binCount = plen - hdr;
            if (binCount !== 64 && binCount !== 128 && binCount !== 256) {
                pos += total;
                continue;
            }
            const bins = [];
            for (let i = 0; i < binCount; i++) {
                push(bins, ord(buf, base + hdr + i));
            }
            let width = bw;
            if (width < 5 || width > 160) {
                width = 20;
            }
            push(samples, {
                type: "ath10k",
                freq1: freq1,
                f_start: freq1 - width / 2,
                f_stop: freq1 + width / 2,
                noise: noise,
                bins: downsampleBins(bins, TARGET_BINS)
            });
        }
        else if (typ === ATH_FFT_SAMPLE_HT20) {
            /* tlv + max_exp(1) + freq(2) + rssi(1) + noise(1) + max_mag(2) + max_index(1) + bitmap(1) + tsf(8) + data(56) = 3+73 */
            if (total < 3 + 17 + 56) {
                pos += total;
                continue;
            }
            const freq = be16(buf, base + 1);
            const noise = ord(buf, base + 4);
            let noiseS = noise;
            if (noiseS >= 128) {
                noiseS -= 256;
            }
            const bins = [];
            const dataOff = base + 17;
            for (let i = 0; i < 56; i++) {
                push(bins, ord(buf, dataOff + i));
            }
            push(samples, {
                type: "ht20",
                freq1: freq,
                f_start: freq - 10,
                f_stop: freq + 10,
                noise: noiseS,
                bins: downsampleBins(bins, TARGET_BINS)
            });
        }
        else if (typ === ATH_FFT_SAMPLE_HT20_40) {
            if (total < 3 + 17 + 128) {
                pos += total;
                continue;
            }
            const freq = be16(buf, base + 1);
            const noise = ord(buf, base + 4);
            let noiseS = noise;
            if (noiseS >= 128) {
                noiseS -= 256;
            }
            const bins = [];
            const dataOff = base + 17;
            for (let i = 0; i < 128; i++) {
                push(bins, ord(buf, dataOff + i));
            }
            push(samples, {
                type: "ht40",
                freq1: freq,
                f_start: freq - 20,
                f_stop: freq + 20,
                noise: noiseS,
                bins: downsampleBins(bins, TARGET_BINS)
            });
        }
        pos += total;
    }
    return samples;
};


const FFT_READ_MAX = 49152;

function readFftBuffer(path)
{
    const st = fs.stat(path);
    if (!st) {
        return null;
    }
    const bytes = int(st.size);
    if (bytes <= 0) {
        return null;
    }
    const f = fs.open(path, "r");
    if (!f) {
        return null;
    }
    const n = bytes > FFT_READ_MAX ? FFT_READ_MAX : bytes;
    const buf = f.read(n);
    f.close();
    return buf;
}

/**
 * Collapse many TLV samples into one sweep row (per-bin max).
 */
export function samplesToSweep(samples)
{
    if (!length(samples)) {
        return null;
    }
    const first = samples[0];
    const nb = length(first.bins);
    const bins = [];
    for (let i = 0; i < nb; i++) {
        push(bins, 0);
    }
    let noiseSum = 0;
    for (let s = 0; s < length(samples); s++) {
        const sample = samples[s];
        noiseSum += sample.noise;
        for (let i = 0; i < nb && i < length(sample.bins); i++) {
            if (sample.bins[i] > bins[i]) {
                bins[i] = sample.bins[i];
            }
        }
    }
    return {
        f_start: first.f_start,
        f_stop: first.f_stop,
        noise: int(noiseSum / length(samples)),
        bins: bins
    };
};

export function disableAllSpectral()
{
    const phys = fs.lsdir(DBG_BASE) || [];
    for (let i = 0; i < length(phys); i++) {
        const phy = phys[i];
        if (!match(phy, /^phy/)) {
            continue;
        }
        writeCtl(`${DBG_BASE}/${phy}/ath9k/spectral_scan_ctl`, "disable");
        writeCtl(`${DBG_BASE}/${phy}/ath10k/spectral_scan_ctl`, "disable");
    }
};

export function isAdminRequest(env)
{
    const cookieheader = env?.HTTP_COOKIE || getenv("HTTP_COOKIE") || "";
    if (!cookieheader) {
        return false;
    }
    let key = null;
    const f = fs.open("/etc/shadow");
    if (f) {
        for (let l = f.read("line"); length(l); l = f.read("line")) {
            if (index(l, "root:") === 0) {
                key = trim(l);
                break;
            }
        }
        f.close();
    }
    if (!key) {
        return false;
    }
    const ca = split(cookieheader, ";");
    for (let i = 0; i < length(ca); i++) {
        const cookie = trim(ca[i]);
        if (index(cookie, "authV1=") === 0) {
            return key == b64dec(substr(cookie, 7));
        }
    }
    return false;
};

export function isFiveGhz(iface, channel)
{
    if (channel != null && channel !== -1) {
        const f = hardware.getChannelFrequency(iface, channel);
        if (f != null) {
            return f >= 5000;
        }
    }
    const chans = hardware.getRfChannels(iface) || [];
    if (length(chans) && chans[0].frequency != null) {
        return chans[0].frequency >= 5000;
    }
    return false;
};

export function selectRadio(preferredIface)
{
    const config = radios.getActiveConfiguration() || [];
    if (preferredIface) {
        for (let i = 0; i < length(config); i++) {
            if (config[i].iface === preferredIface) {
                return config[i];
            }
        }
    }

    let mesh5 = null;
    let meshAny = null;
    let any = null;
    for (let i = 0; i < length(config); i++) {
        const r = config[i];
        if (!r?.iface) {
            continue;
        }
        if (!any) {
            any = r;
        }
        const mode = r?.mode?.mode;
        if (!isMeshMode(mode)) {
            continue;
        }
        if (!meshAny) {
            meshAny = r;
        }
        const ch = r.mode?.channel ?? -1;
        if (!mesh5 && isFiveGhz(r.iface, ch)) {
            mesh5 = r;
        }
    }
    return mesh5 || meshAny || any;
};

export function listRadios()
{
    const config = radios.getActiveConfiguration() || [];
    const out = [];
    for (let i = 0; i < length(config); i++) {
        const r = config[i];
        if (!r?.iface) {
            continue;
        }
        const phy = hardware.getPhyDevice(r.iface);
        const chipset = chipsetForPhy(phy);
        const channel = r.mode?.channel ?? -1;
        const five = isFiveGhz(r.iface, channel);
        const paths = spectralPaths(phy, chipset);
        const fftAvailable = !!(paths && fs.access(paths.ctl) && fs.access(paths.relay));
        push(out, {
            iface: r.iface,
            phy: phy,
            chipset: chipset,
            mode: r.mode?.mode || "unknown",
            channel: channel,
            band: five ? "5GHz" : "other",
            fft_paths: !!paths,
            fft_available: fftAvailable,
            selectable: fftAvailable
        });
    }
    return out;
};

export function isFocusBoard(board)
{
    const bid = lc(board || "");
    if (!bid) {
        return false;
    }
    return !!(
        match(bid, /rocket-m/) ||
        match(bid, /rocket m5/) ||
        match(bid, /powerbeam-m5/) ||
        match(bid, /powerbeam m5/) ||
        match(bid, /powerbeam-5ac-500/) ||
        match(bid, /pbe-5ac-500/) ||
        match(bid, /952ui-5ac2nd/) ||
        match(bid, /hap ac lite/) ||
        match(bid, /ubnt,rocket/) ||
        match(bid, /ubnt,powerbeam/)
    );
};

export function supportStatus(cap)
{
    const board = cap?.board || "";
    const rlist = cap?.radios || listRadios();
    let anyFft = !!(cap?.fft_available);
    if (!anyFft) {
        for (let i = 0; i < length(rlist); i++) {
            if (radioHasFft(rlist[i])) {
                anyFft = true;
                break;
            }
        }
    }

    if (anyFft) {
        return { supported: true, message: null };
    }

    const focus = isFocusBoard(board);
    if (!cap?.ok && cap?.error) {
        return {
            supported: false,
            message: `Waterfall is not supported on this hardware: ${cap.error}. Focus devices: Rocket M5, PowerBeam 500 / 500 AC, and MikroTik hAP ac lite (5 GHz).`
        };
    }
    if (focus) {
        return {
            supported: false,
            message: `Waterfall is not available on this node: spectral FFT debugfs was not found (board looks like a focus device: ${board || "unknown"}). ATH_SPECTRAL / relayfs may be missing from this firmware build.`
        };
    }
    return {
        supported: false,
        message: `Waterfall is not supported on this hardware${board ? ` (${board})` : ""}. Supported focus devices: Ubiquiti Rocket M5, PowerBeam 500 / PowerBeam 500 AC, and MikroTik hAP ac lite (5 GHz radio).`
    };
};

export function probeCapability(preferredIface)
{
    const board = hardware.getBoardId() || hardware.getRadioName() || "";
    const radio = selectRadio(preferredIface);
    if (!radio || !radio.iface) {
        const cap = {
            ok: false,
            error: "No active radio found",
            version: packageVersion(),
            board: board,
            radios: listRadios(),
            fft_available: false
        };
        const sup = supportStatus(cap);
        cap.supported = sup.supported;
        cap.unsupported_message = sup.message;
        return cap;
    }
    const iface = radio.iface;
    const phy = hardware.getPhyDevice(iface);
    const chipset = chipsetForPhy(phy);
    const paths = spectralPaths(phy, chipset);
    const hasCtl = paths ? !!fs.access(paths.ctl) : false;
    const hasRelay = paths ? !!fs.access(paths.relay) : false;
    const fftAvailable = hasCtl && hasRelay && (chipset === "ath9k" || chipset === "ath10k");

    const mode = radio.mode?.mode || "unknown";
    const channel = radio.mode?.channel ?? -1;
    let freq = -1;
    if (channel !== -1) {
        freq = hardware.getChannelFrequency(iface, channel) || -1;
    }
    const five = isFiveGhz(iface, channel);

    const cap = {
        ok: true,
        version: packageVersion(),
        board: board,
        iface: iface,
        phy: phy,
        chipset: chipset,
        mode: mode,
        channel: channel,
        frequency_mhz: freq,
        band: five ? "5GHz" : "other",
        fft_available: fftAvailable,
        spectral_ctl: hasCtl,
        spectral_relay: hasRelay,
        paths: paths,
        note: focusNote(chipset, fftAvailable, board),
        radios: listRadios()
    };
    const sup = supportStatus(cap);
    cap.supported = sup.supported;
    cap.unsupported_message = sup.message;
    return cap;
};

export function getSurveySummary(iface)
{
    const survey = nl80211.request(nl80211.const.NL80211_CMD_GET_SURVEY, nl80211.const.NLM_F_DUMP, { dev: iface }) || [];
    const out = [];
    for (let i = 0; i < length(survey); i++) {
        if (survey[i].dev !== iface) {
            continue;
        }
        const si = survey[i].survey_info || {};
        push(out, {
            frequency: survey[i].frequency || si.frequency || null,
            noise: si.noise ?? null,
            time: si.time ?? null,
            time_busy: si.time_busy ?? null,
            time_rx: si.time_rx ?? null,
            time_tx: si.time_tx ?? null
        });
    }
    return out;
};

function readSessionState()
{
    if (!fs.access(SESSION_JSON)) {
        return { running: false };
    }
    try {
        return json(fs.readfile(SESSION_JSON)) || { running: false };
    }
    catch (_) {
        return { running: false };
    }
}

function writeSessionState(state)
{
    fs.writefile(SESSION_JSON, sprintf("%J", state));
}

export function readCache()
{
    if (!fs.access(CACHE_JSON)) {
        return {
            ok: true,
            version: packageVersion(),
            have_cache: false,
            sweeps: [],
            meta: null
        };
    }
    try {
        const c = json(fs.readfile(CACHE_JSON));
        c.ok = true;
        c.have_cache = length(c.sweeps || []) > 0;
        c.version = packageVersion();
        return c;
    }
    catch (_) {
        return {
            ok: false,
            error: "Corrupt waterfall cache",
            have_cache: false,
            sweeps: [],
            version: packageVersion()
        };
    }
};

export function writeCache(cache)
{
    fs.writefile(CACHE_JSON, sprintf("%J", cache));
};

export function sessionIsRunning()
{
    const st = readSessionState();
    if (!st.running) {
        return false;
    }
    if (fs.access(SESSION_PID)) {
        const pid = trim(fs.readfile(SESSION_PID) || "");
        if (pid && fs.access(`/proc/${pid}`)) {
            return true;
        }
    }
    /* Stale state — force idle and ensure RF is restored */
    st.running = false;
    writeSessionState(st);
    disableAllSpectral();
    return false;
};

/**
 * One-shot capture (CLI/debug). Always disables spectral afterward.
 */
export function captureSpectral(preferredIface)
{
    const cap = probeCapability(preferredIface);
    if (!cap.ok) {
        return cap;
    }
    if (!cap.fft_available) {
        return {
            ok: false,
            error: "Spectral FFT not available on this radio",
            capability: cap
        };
    }

    const ctl = cap.paths.ctl;
    const relay = cap.paths.relay;

    system(`dd if=${relay} of=/dev/null bs=4096 count=16 2>/dev/null`);
    if (!writeCtl(ctl, "background")) {
        disableAllSpectral();
        return { ok: false, error: `Cannot write ${ctl}`, capability: cap };
    }
    if (!writeCtl(ctl, "trigger")) {
        disableAllSpectral();
        return { ok: false, error: "Cannot trigger spectral scan", capability: cap };
    }
    system("sleep 1");
    system(`dd if=${relay} of=${FFT_OUT} bs=4096 count=8 2>/dev/null`);
    disableAllSpectral();

    const st = fs.stat(FFT_OUT);
    const bytes = st ? int(st.size) : 0;
    let sweep = null;
    if (bytes > 0) {
        const buf = readFftBuffer(FFT_OUT);
        if (buf) {
            sweep = samplesToSweep(parseFftTlvs(buf, 24));
        }
    }

    return {
        ok: bytes > 0,
        error: bytes > 0 ? null : "No FFT samples captured (empty relay). Radio may be idle or spectral unsupported in this mode.",
        capability: cap,
        fft_file: FFT_OUT,
        fft_bytes: bytes,
        sweep: sweep,
        survey: getSurveySummary(cap.iface),
        experimental: cap.chipset === "ath10k"
    };
};

/**
 * Bounded RF session: spectral on for <= durationSec, always disable, write RAM cache.
 */
export function runSession(preferredIface, durationSec)
{
    if (durationSec == null || durationSec <= 0 || durationSec > 30) {
        durationSec = SESSION_DEFAULT_SEC;
    }
    fs.unlink(SESSION_STOP);

    const cap = probeCapability(preferredIface);
    const started = nowSec();
    const ends = started + durationSec;
    const sweeps = [];

    writeSessionState({
        running: true,
        started_at: started,
        ends_at: ends,
        iface: cap.iface,
        chipset: cap.chipset,
        version: packageVersion()
    });
    /* PID is written by the shell wrapper when launched async */

    let error = null;
    let fStart = null;
    let fStop = null;

    if (!cap.ok || !cap.fft_available) {
        error = cap.unsupported_message || cap.error || "FFT not available";
    }
    else {
        const ctl = cap.paths.ctl;
        const relay = cap.paths.relay;
        try {
            system(`dd if=${relay} of=/dev/null bs=4096 count=8 2>/dev/null`);
            if (!writeCtl(ctl, "background")) {
                error = `Cannot write ${ctl}`;
            }
            else {
                while (nowSec() < ends) {
                    if (fs.access(SESSION_STOP)) {
                        break;
                    }
                    if (!writeCtl(ctl, "trigger")) {
                        error = "Cannot trigger spectral scan";
                        break;
                    }
                    system("sleep 1");
                    system(`dd if=${relay} of=${FFT_OUT} bs=4096 count=4 2>/dev/null`);
                    const st = fs.stat(FFT_OUT);
                    const bytes = st ? int(st.size) : 0;
                    if (bytes > 0) {
                        const buf = readFftBuffer(FFT_OUT);
                        if (buf) {
                            const sweep = samplesToSweep(parseFftTlvs(buf, 16));
                            if (sweep) {
                                if (fStart == null) {
                                    fStart = sweep.f_start;
                                    fStop = sweep.f_stop;
                                }
                                push(sweeps, sweep.bins);
                                if (length(sweeps) >= MAX_SWEEPS) {
                                    break;
                                }
                            }
                        }
                    }
                    if (fs.access(SESSION_STOP)) {
                        break;
                    }
                }
            }
        }
        catch (e) {
            error = `${e}`;
        }
    }

    disableAllSpectral();
    fs.unlink(SESSION_STOP);
    fs.unlink(SESSION_PID);

    const ended = nowSec();
    const cache = {
        ok: length(sweeps) > 0,
        error: length(sweeps) > 0 ? null : (error || "No sweeps captured"),
        have_cache: length(sweeps) > 0,
        version: packageVersion(),
        meta: {
            board: cap.board,
            iface: cap.iface,
            phy: cap.phy,
            chipset: cap.chipset,
            band: cap.band,
            f_start: fStart,
            f_stop: fStop,
            started_at: started,
            ended_at: ended,
            duration_sec: ended - started,
            sweep_count: length(sweeps),
            experimental: cap.chipset === "ath10k",
            note: "RF spectral session complete; radio restored to normal use."
        },
        sweeps: sweeps
    };
    writeCache(cache);
    writeSessionState({
        running: false,
        started_at: started,
        ends_at: ends,
        ended_at: ended,
        iface: cap.iface,
        chipset: cap.chipset,
        sweep_count: length(sweeps),
        version: packageVersion()
    });
    return cache;
};

/**
 * Start background session worker (returns immediately). Admin must gate callers.
 */
export function startSessionAsync(preferredIface, durationSec)
{
    if (sessionIsRunning()) {
        return {
            ok: false,
            error: "A waterfall session is already running",
            session: readSessionState()
        };
    }
    const cap = probeCapability(preferredIface);
    if (!cap.supported || !cap.fft_available) {
        return {
            ok: false,
            error: cap.unsupported_message || "Spectral FFT not available",
            capability: cap
        };
    }
    if (durationSec == null || durationSec <= 0 || durationSec > 30) {
        durationSec = SESSION_DEFAULT_SEC;
    }
    const ifaceArg = preferredIface ? ` -i ${preferredIface}` : "";
    fs.unlink(SESSION_STOP);
    const started = nowSec();
    writeSessionState({
        running: true,
        started_at: started,
        ends_at: started + durationSec,
        iface: cap.iface,
        chipset: cap.chipset,
        version: packageVersion()
    });
    system(`waterfall-session${ifaceArg} -d ${durationSec} >/tmp/waterfall-session.log 2>&1 &`);
    return {
        ok: true,
        started: true,
        started_at: started,
        ends_at: started + durationSec,
        duration_sec: durationSec,
        iface: cap.iface,
        chipset: cap.chipset,
        warning: "Spectral capture disrupts RF for up to 30s. Reconnect afterward to view the cached waterfall."
    };
};

export function stopSession()
{
    fs.writefile(SESSION_STOP, "1\n");
    /* Give worker a moment, then force-disable RF */
    system("sleep 1");
    disableAllSpectral();
    const st = readSessionState();
    st.running = false;
    st.stopped_at = nowSec();
    writeSessionState(st);
    return { ok: true, stopped: true, session: st, cache: readCache() };
};

export function sessionStatus(preferredIface)
{
    const rlist = listRadios();
    const cap = probeCapability(preferredIface);
    const running = sessionIsRunning();
    const sess = readSessionState();
    const cache = readCache();
    return {
        ok: true,
        version: packageVersion(),
        running: running,
        session: sess,
        have_cache: cache.have_cache,
        sweep_count: length(cache.sweeps || []),
        radios: rlist,
        selected_iface: preferredIface || cap.iface || null,
        capability: {
            supported: cap.supported,
            unsupported_message: cap.unsupported_message,
            iface: cap.iface,
            phy: cap.phy,
            chipset: cap.chipset,
            band: cap.band,
            fft_available: cap.fft_available,
            board: cap.board,
            note: cap.note
        }
    };
};

export function formatProbeReport(cap)
{
    const lines = [];
    push(lines, `waterfall ${cap.version || packageVersion()}`);
    if (cap.board) {
        push(lines, `board ${cap.board}`);
    }
    if (cap.supported === false) {
        push(lines, "NOT SUPPORTED");
        if (cap.unsupported_message) {
            push(lines, cap.unsupported_message);
        }
    }
    if (!cap.ok) {
        if (cap.supported !== false) {
            push(lines, `ERROR: ${cap.error}`);
        }
        return join("\n", lines) + "\n";
    }
    push(lines, `selected ${cap.iface}  phy ${cap.phy}  chipset ${cap.chipset}  band ${cap.band}`);
    push(lines, `mode ${cap.mode}  channel ${cap.channel}  freq ${cap.frequency_mhz} MHz`);
    push(lines, `fft_available ${cap.fft_available}  ctl ${cap.spectral_ctl}  relay ${cap.spectral_relay}`);
    if (cap.supported !== false) {
        push(lines, cap.note);
    }
    if (cap.radios && length(cap.radios) > 1) {
        push(lines, "radios:");
        for (let i = 0; i < length(cap.radios); i++) {
            const r = cap.radios[i];
            push(lines, `  ${r.iface} ${r.phy} ${r.chipset} ${r.band} mode=${r.mode} ch=${r.channel}`);
        }
        push(lines, "(auto-select prefers 5 GHz mesh; pass -i / iface= to override)");
    }
    if (cap.supported === false) {
        return join("\n", lines) + "\n";
    }
    push(lines, "RF note: spectral capture disrupts the radio for up to 30s; use 'waterfall session'.");
    const survey = getSurveySummary(cap.iface);
    if (length(survey)) {
        push(lines, "survey:");
        const lim = length(survey) > 8 ? 8 : length(survey);
        for (let i = 0; i < lim; i++) {
            const s = survey[i];
            push(lines, `  freq=${s.frequency} noise=${s.noise}`);
        }
        if (length(survey) > lim) {
            push(lines, `  ... ${length(survey) - lim} more`);
        }
    }
    else {
        push(lines, "survey: (none)");
    }
    return join("\n", lines) + "\n";
};

export function formatCaptureReport(result)
{
    const lines = [];
    push(lines, `waterfall ${packageVersion()} capture`);
    if (result.capability) {
        push(lines, trim(formatProbeReport(result.capability)));
    }
    if (!result.ok) {
        push(lines, `ERROR: ${result.error}`);
        return join("\n", lines) + "\n";
    }
    if (result.experimental) {
        push(lines, "NOTE: ath10k capture is experimental (hAP ac lite 5 GHz / PowerBeam 500 AC class).");
    }
    push(lines, `fft_file ${result.fft_file}  bytes ${result.fft_bytes}`);
    if (result.sweep) {
        push(lines, `parsed bins ${length(result.sweep.bins)}  f ${result.sweep.f_start}-${result.sweep.f_stop} MHz  noise ${result.sweep.noise}`);
    }
    push(lines, "Spectral disabled after capture (RF restored).");
    return join("\n", lines) + "\n";
};
