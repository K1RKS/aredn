/**
 * Waterfall package library.
 * RF spectrum probe/capture for 5 GHz AREDN radios.
 * Focus: Rocket M5, PowerBeam 500 / 500 AC, MikroTik hAP ac lite.
 *
 * Capture modes:
 *   ath9k  — spectral FFT via spectral_scan_ctl.
 *            Current/single: background+trigger (mesh-safer).
 *            ALL/wide stitch: classic kn6plv path — chanscan + iw scan freq
 *            (temporary mesh RF interrupt; denser full-band FFT).
 *   ath10k — spectral FFT via isolated worker (flock + hard timeout + local
 *            Wi-Fi recovery). Survey waterfall is the automatic fallback if
 *            FFT returns empty, is in cooldown, or recovery fires.
 *
 * ath10k spectral_scan_ctl can wedge QCA988x on IBSS/mesh; the worker never
 * leaves ctl enabled, serializes captures, and recovers with iface bounce /
 * wifi reload (not power cycle) when the hard timeout fires. Do not use
 * Tim’s iw-scan-while-spectral as the ath10k primary path.
 */

import * as fs from "fs";
import * as math from "math";
import * as nl80211 from "nl80211";
import * as radios from "aredn.radios";
import * as hardware from "aredn.hardware";

const FFT_OUT = "/tmp/waterfall-fft.bin";
/* Heatmap history in RAM (/tmp). Cleared on reboot — avoids flash wear. */
const CACHE_JSON = "/tmp/waterfall-cache.json";
const CACHE_PREFIX = "/tmp/waterfall-cache-";
const CACHE_FLASH_DIR = "/etc/waterfall/cache"; /* legacy 0.2.37 location; cleared on upgrade */
const CACHE_HISTORY_SLOTS = 3; /* slots 1..3 behind Current (0) */
const SESSION_JSON = "/tmp/waterfall-session.json";
const SESSION_PID = "/tmp/waterfall-session.pid";
const SESSION_STOP = "/tmp/waterfall-session.stop";
const DBG_BASE = "/sys/kernel/debug/ieee80211";

const ATH_FFT_SAMPLE_HT20 = 1;
const ATH_FFT_SAMPLE_HT20_40 = 2;
const ATH_FFT_SAMPLE_ATH10K = 3;

const SESSION_DEFAULT_SEC = 30;
const SESSION_MAX_SEC = 600;
const MAX_SWEEPS = 400;
const TARGET_BINS = 64;
const ATH10K_FFT_HARD_TIMEOUT = 4;
const ATH10K_FFT_MAX_SEC = 5; /* fragile QCA9887: short FFT only when opted in */
const SPECTRAL_COOLDOWN = "/tmp/waterfall-spectral.cooldown";
const SCAN_HOLD = "/tmp/waterfall-scan.active";
const PERSIST_LOG = "/etc/waterfall/session.log";
/* kn6plv-style absolute floor; bins stored as level = max(0, dBm - MIN_SIG). */
const MIN_SIG_DBM = -125;
const MAX_SIG_DBM = -35;
const SPECTRAL_COUNT_DEFAULT = 32;

export function packageVersion()
{
    return "0.2.41-r0";
};

/**
 * QCA988x on MikroTik (hAP ac lite 5 GHz, etc.): spectral FFT can hard-hang
 * the SoC (DtD/Ethernet included). Default to survey; FFT is opt-in + short.
 */
export function isFragileAth10k(board, chipset)
{
    if (chipset !== "ath10k") {
        return false;
    }
    const bid = lc(board || "");
    if (match(bid, /mikrotik|952ui-5ac2nd|hap ac|qca9887|qca988x|rb952/)) {
        return true;
    }
    /* Prefer survey whenever board string is empty but phy is ath10k on small RAM nodes. */
    return true;
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

/**
 * ath9k / ath10k both have a capture path (FFT and/or survey).
 */
export function isCaptureSafe(chipset)
{
    return chipset === "ath9k" || chipset === "ath10k";
};

export function captureModeForChipset(chipset, board)
{
    if (chipset === "ath9k") {
        return "fft";
    }
    if (chipset === "ath10k") {
        return isFragileAth10k(board, chipset) ? "survey" : "fft";
    }
    return null;
};

function ath10kNote(board)
{
    const bid = lc(board || "");
    if (match(bid, /952ui-5ac2nd|hap ac lite/)) {
        return "hAP ac lite 5 GHz (QCA9887): default is survey (safe). Experimental FFT is opt-in, ≤5s, disable-only recover (no wifi reload).";
    }
    return "ath10k: default survey on fragile QCA988x; FFT opt-in with short pulses and disable-only recover.";
}

function focusNote(chipset, fftAvailable, board, captureSafe, mode)
{
    if (chipset === "ath9k" && fftAvailable) {
        return "ath9k spectral FFT available (Rocket M5 / PowerBeam M5 class; also hAP ac lite 2.4 GHz). Current-channel: background+trigger; ALL/wide: classic chanscan+iw scan (temporary mesh RF interrupt).";
    }
    if (chipset === "ath10k") {
        return ath10kNote(board);
    }
    if (chipset === "unknown") {
        return "Chipset not recognized for spectral capture.";
    }
    return `Chipset ${chipset} has no waterfall path in this package yet.`;
}

function persistLog(msg)
{
    try {
        system("mkdir -p /etc/waterfall 2>/dev/null");
        const line = `${int(clock()[0])} ${msg}\n`;
        const f = fs.open(PERSIST_LOG, "a");
        if (f) {
            f.write(line);
            f.close();
        }
    }
    catch (_) {
    }
}

function petHardwareWatchdog()
{
    /* Keep HW watchdog fed during long survey sessions so a busy node is not
     * rebooted mid-run. Do not disable the watchdog. */
    try {
        if (!fs.access("/dev/watchdog")) {
            return;
        }
        const f = fs.open("/dev/watchdog", "w");
        if (f) {
            f.write("\0");
            f.close();
        }
    }
    catch (_) {
    }
}

function beginScanHold(meta)
{
    try {
        const at = int(clock()[0]);
        const body = sprintf("%.2J\n", meta || { active: true, at: at });
        fs.writefile(SCAN_HOLD, body);
        fs.writefile("/tmp/waterfall-hold-wireless_monitor", "1\n");
        persistLog(`scan-hold begin ${meta?.iface || ""} mode=${meta?.mode || "?"}`);
    }
    catch (_) {
    }
    petHardwareWatchdog();
}

function endScanHold(reason)
{
    try {
        fs.unlink(SCAN_HOLD);
        fs.unlink("/tmp/waterfall-hold-wireless_monitor");
        persistLog(`scan-hold end ${reason || ""}`);
    }
    catch (_) {
    }
    petHardwareWatchdog();
}

function radioHasFft(r)
{
    if (!r?.phy || (r.chipset !== "ath9k" && r.chipset !== "ath10k")) {
        return false;
    }
    const paths = spectralPaths(r.phy, r.chipset);
    if (!paths) {
        return false;
    }
    return !!fs.access(paths.ctl) && !!fs.access(paths.relay);
}

function radioHasSurvey(r)
{
    return !!(r?.iface && r.chipset === "ath10k");
}

function radioSelectable(r)
{
    return radioHasFft(r) || radioHasSurvey(r);
}

function spectralCooldownActive()
{
    if (!fs.access(SPECTRAL_COOLDOWN)) {
        return false;
    }
    /* Use clock() directly — calling nowSec() from nested session helpers
     * can throw "undeclared variable nowSec" on some ucode builds. */
    const until = int(trim(fs.readfile(SPECTRAL_COOLDOWN) || "0"));
    const now = int(clock()[0]);
    if (until <= now) {
        fs.unlink(SPECTRAL_COOLDOWN);
        return false;
    }
    return true;
};

/**
 * Run isolated ath10k FFT capture. durationSec>0 streams for that wall time.
 */
export function runAth10kFftPulse(iface, phy, allowScan, durationSec)
{
    if (!iface || !phy) {
        return { ok: false, bytes: 0, exit: 5, recovered: false, error: "missing iface/phy" };
    }
    if (spectralCooldownActive()) {
        return { ok: false, bytes: 0, exit: 3, recovered: false, error: "spectral cooldown active after prior failure" };
    }
    const scan = allowScan ? " --scan" : "";
    let durArg = "";
    let hard = ATH10K_FFT_HARD_TIMEOUT;
    if (durationSec != null && durationSec > 0) {
        durArg = ` -d ${int(durationSec)}`;
        hard = int(durationSec) + 8;
    }
    const rc = system(`/usr/bin/waterfall-ath10k-fft -i ${iface} -p ${phy} -o ${FFT_OUT} -t ${hard}${durArg}${scan} --safe-recover >/tmp/waterfall-ath10k-fft.log 2>&1`);
    let exitCode = rc;
    if (exitCode > 255) {
        exitCode = exitCode >> 8;
    }
    const st = fs.stat(FFT_OUT);
    const bytes = st ? int(st.size) : 0;
    const recovered = exitCode === 4 || (exitCode !== 0 && spectralCooldownActive());
    return {
        ok: exitCode === 0 && bytes > 0,
        bytes: bytes,
        exit: exitCode,
        recovered: recovered,
        error: exitCode === 0 ? null :
            (exitCode === 1 ? "empty FFT relay" :
            (exitCode === 2 ? "spectral lock busy" :
            (exitCode === 3 ? "spectral cooldown" :
            (exitCode === 4 || recovered ? "spectral timeout — Wi-Fi recovery ran" :
            `ath10k FFT worker exit ${exitCode}`))))
    };
};

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

function writeSpectralCount(paths, count)
{
    if (!paths?.count) {
        return false;
    }
    return writeCtl(paths.count, `${count != null ? count : SPECTRAL_COUNT_DEFAULT}`);
}

function s8(b)
{
    return b >= 128 ? b - 256 : b;
}

function log10safe(x)
{
    if (x == null || x <= 0) {
        return -999;
    }
    if (math.log10) {
        return math.log10(x);
    }
    return math.log(x) / math.log(10);
}

/* kn6plv absolute dBm → non-negative heatmap level (0 = empty / below floor). */
function powerToLevel(sig)
{
    if (sig == null || sig < MIN_SIG_DBM || sig > MAX_SIG_DBM) {
        return 0;
    }
    return int(sig - MIN_SIG_DBM);
}

function nowSec()
{
    return int(clock()[0]);
}

function nowFrac()
{
    const c = clock();
    /* Force float: ucode integer-divides otherwise and drops sub-second time. */
    return c[0] + c[1] / 1000000000.0;
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

function be32(buf, off)
{
    return (ord(buf, off) * 16777216) + (ord(buf, off + 1) * 65536) +
        (ord(buf, off + 2) * 256) + ord(buf, off + 3);
}

/* Approximate be64 as Number (fine for TSF deltas within a short session). */
function be64(buf, off)
{
    const hi = be32(buf, off);
    const lo = be32(buf, off + 4);
    return hi * 4294967296 + lo;
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

/* ath10k reports 11/22/44/88 for 10/20/40/80-ish channel widths. */
function ath10kChanWidthMhz(bw)
{
    if (bw == null) {
        return 20;
    }
    if (bw === 11 || bw === 10) {
        return 10;
    }
    if (bw === 22 || bw === 20) {
        return 20;
    }
    if (bw === 44 || bw === 40) {
        return 40;
    }
    if (bw === 88 || bw === 80) {
        return 80;
    }
    if (bw >= 5 && bw <= 160) {
        return bw;
    }
    return 20;
}

/**
 * Parse spectral TLV binary into sample objects { type, f_start, f_stop, noise, bins }.
 * bins are kn6plv-style levels (dBm − MIN_SIG_DBM), not raw FFT magnitudes.
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
        /* Misaligned relay dumps are common — byte-resync instead of aborting. */
        if (typ !== ATH_FFT_SAMPLE_HT20 && typ !== ATH_FFT_SAMPLE_HT20_40 &&
            typ !== ATH_FFT_SAMPLE_ATH10K) {
            pos++;
            continue;
        }
        if (plen < 16 || plen > 512 || pos + total > n) {
            pos++;
            continue;
        }
        const base = pos + 3;

        if (typ === ATH_FFT_SAMPLE_ATH10K) {
            const hdr = 26;
            if (plen < hdr + 16) {
                pos++;
                continue;
            }
            const bw = ord(buf, base);
            const freq1 = be16(buf, base + 1);
            const noise = be16s(buf, base + 5);
            const rssi = s8(ord(buf, base + 22));
            const maxExp = ord(buf, base + 25);
            const binCount = plen - hdr;
            if (noise < -140 || noise > -20 || freq1 < 4900 || freq1 > 6100 ||
                (binCount !== 64 && binCount !== 128 && binCount !== 256)) {
                pos++;
                continue;
            }
            const tsf = be64(buf, base + 13);
            let datasqsum = 0;
            const raw = [];
            for (let i = 0; i < binCount; i++) {
                const data = ord(buf, base + hdr + i) << maxExp;
                push(raw, data);
                datasqsum += data * data;
            }
            const levels = [];
            if (datasqsum > 0) {
                const signalOffset = noise + rssi - 10 * log10safe(datasqsum);
                for (let i = 0; i < binCount; i++) {
                    const data = raw[i];
                    if (data > 0) {
                        push(levels, powerToLevel(signalOffset + 20 * log10safe(data)));
                    }
                    else {
                        push(levels, 0);
                    }
                }
            }
            else {
                for (let i = 0; i < binCount; i++) {
                    push(levels, 0);
                }
            }
            let width = ath10kChanWidthMhz(bw);
            push(samples, {
                type: "ath10k",
                freq1: freq1,
                f_start: freq1 - width / 2.0,
                f_stop: freq1 + width / 2.0,
                noise: noise,
                tsf: tsf,
                bins: downsampleBins(levels, TARGET_BINS)
            });
            pos += total;
        }
        else if (typ === ATH_FFT_SAMPLE_HT20) {
            /* tlv + max_exp(1) + freq(2) + rssi(1) + noise(1) + max_mag(2) + max_index(1) + bitmap(1) + tsf(8) + data(56) */
            if (total < 3 + 17 + 56 || plen !== 73) {
                pos++;
                continue;
            }
            const maxExp = ord(buf, base);
            const freq = be16(buf, base + 1);
            if (freq < 2300 || freq > 6100) {
                pos++;
                continue;
            }
            const rssi = s8(ord(buf, base + 3));
            const noiseS = s8(ord(buf, base + 4));
            const dataOff = base + 17;
            let datasqsum = 0;
            const raw = [];
            for (let i = 0; i < 56; i++) {
                const data = ord(buf, dataOff + i) << maxExp;
                const datasq = data * data;
                push(raw, datasq);
                datasqsum += datasq;
            }
            const levels = [];
            if (datasqsum > 0) {
                for (let i = 0; i < 56; i++) {
                    const datasq = raw[i];
                    if (datasq > 0) {
                        push(levels, powerToLevel(noiseS + rssi + 10 * log10safe(datasq / datasqsum)));
                    }
                    else {
                        push(levels, 0);
                    }
                }
            }
            else {
                for (let i = 0; i < 56; i++) {
                    push(levels, 0);
                }
            }
            push(samples, {
                type: "ht20",
                freq1: freq,
                f_start: freq - 10,
                f_stop: freq + 10,
                noise: noiseS,
                bins: downsampleBins(levels, TARGET_BINS)
            });
            pos += total;
        }
        else if (typ === ATH_FFT_SAMPLE_HT20_40) {
            if (total < 3 + 17 + 128) {
                pos++;
                continue;
            }
            const maxExp = ord(buf, base);
            const freq = be16(buf, base + 1);
            if (freq < 2300 || freq > 6100) {
                pos++;
                continue;
            }
            const rssi = s8(ord(buf, base + 3));
            const noiseS = s8(ord(buf, base + 4));
            const dataOff = base + 17;
            let datasqsum = 0;
            const raw = [];
            const binCount = 128;
            for (let i = 0; i < binCount; i++) {
                const data = ord(buf, dataOff + i) << maxExp;
                const datasq = data * data;
                push(raw, datasq);
                datasqsum += datasq;
            }
            const levels = [];
            if (datasqsum > 0) {
                for (let i = 0; i < binCount; i++) {
                    const datasq = raw[i];
                    if (datasq > 0) {
                        push(levels, powerToLevel(noiseS + rssi + 10 * log10safe(datasq / datasqsum)));
                    }
                    else {
                        push(levels, 0);
                    }
                }
            }
            else {
                for (let i = 0; i < binCount; i++) {
                    push(levels, 0);
                }
            }
            push(samples, {
                type: "ht40",
                freq1: freq,
                f_start: freq - 20,
                f_stop: freq + 20,
                noise: noiseS,
                bins: downsampleBins(levels, TARGET_BINS)
            });
            pos += total;
        }
        else {
            pos++;
        }
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
 * Collapse many TLV samples into one sweep row (per-bin max) — one-shot summary only.
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

/**
 * One heatmap row per FFT TLV sample (time progresses down the waterfall).
 */
export function samplesToRows(samples)
{
    const rows = [];
    if (!samples) {
        return rows;
    }
    for (let i = 0; i < length(samples); i++) {
        const s = samples[i];
        if (!s?.bins || !length(s.bins)) {
            continue;
        }
        push(rows, {
            f_start: s.f_start,
            f_stop: s.f_stop,
            noise: s.noise,
            tsf: s.tsf,
            bins: s.bins
        });
    }
    return rows;
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

/**
 * Build thinned MHz list for iw scan freq (kn6plv waterfall-update style).
 */
function buildChanscanFreqList(plan)
{
    const hops = plan?.hop_channels || plan?.sections || [];
    const f0 = plan?.f_start;
    const f1 = plan?.f_stop;
    const bw = plan?.scan_bandwidth != null ? plan.scan_bandwidth :
        (plan?.plot_bandwidth != null ? plan.plot_bandwidth : 10);
    let step = int(bw / 10);
    if (step < 1) {
        step = 1;
    }
    const freqs = [];
    const n = length(hops);
    for (let i = 0; i < n; i++) {
        const h = hops[i];
        if (h == null || h.frequency == null) {
            continue;
        }
        const f = int(h.frequency);
        if (f0 != null && f < f0) {
            continue;
        }
        if (f1 != null && f > f1) {
            continue;
        }
        if (i === 0 || i === n - 1 || (i % step) === 0) {
            push(freqs, f);
        }
    }
    return freqs;
};

/**
 * Classic kn6plv ath9k full-band capture: chanscan + iw scan freq list + relay read.
 * Temporarily interrupts mesh RF. Always disables ctl on exit.
 */
export function captureAth9kChanscan(iface, phy, freqList)
{
    if (!iface || !phy) {
        return { ok: false, bytes: 0, error: "missing iface/phy" };
    }
    const paths = spectralPaths(phy, "ath9k");
    if (!paths || !fs.access(paths.ctl) || !fs.access(paths.relay)) {
        return { ok: false, bytes: 0, error: "ath9k spectral paths missing" };
    }
    const freqs = freqList || [];
    if (!length(freqs)) {
        return { ok: false, bytes: 0, error: "empty chanscan freq list" };
    }
    let freqArg = "";
    for (let i = 0; i < length(freqs); i++) {
        freqArg += ` ${int(freqs[i])}`;
    }
    try {
        system(`dd if=${paths.relay} of=/dev/null bs=4096 count=16 2>/dev/null`);
        writeSpectralCount(paths, SPECTRAL_COUNT_DEFAULT);
        if (!writeCtl(paths.ctl, "chanscan")) {
            disableAllSpectral();
            return { ok: false, bytes: 0, error: "Cannot write chanscan to spectral_scan_ctl" };
        }
        system(`iw dev ${iface} scan freq${freqArg} passive >/dev/null 2>&1`);
        writeCtl(paths.ctl, "disable");
        system(`dd if=${paths.relay} of=${FFT_OUT} bs=4096 count=32 2>/dev/null`);
    }
    catch (e) {
        disableAllSpectral();
        return { ok: false, bytes: 0, error: `${e}` };
    }
    disableAllSpectral();
    const st = fs.stat(FFT_OUT);
    const bytes = st ? int(st.size) : 0;
    return {
        ok: bytes > 0,
        bytes: bytes,
        error: bytes > 0 ? null : "No FFT samples from chanscan+iw scan"
    };
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

    let mesh5Safe = null;
    let meshSafe = null;
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
        const phy = hardware.getPhyDevice(r.iface);
        const chipset = chipsetForPhy(phy);
        const safe = isCaptureSafe(chipset);
        const ch = r.mode?.channel ?? -1;
        const five = isFiveGhz(r.iface, ch);
        if (five && !mesh5) {
            mesh5 = r;
        }
        if (safe && !meshSafe) {
            meshSafe = r;
        }
        if (safe && five && !mesh5Safe) {
            mesh5Safe = r;
        }
    }
    /* Prefer 5 GHz mesh when a capture path exists (FFT or survey). */
    return mesh5Safe || meshSafe || mesh5 || meshAny || any;
};

export function listRadios()
{
    const config = radios.getActiveConfiguration() || [];
    const board = hardware.getBoardModel()?.id || hardware.getBoardModel()?.model || "";
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
        const pathsOk = !!(paths && fs.access(paths.ctl) && fs.access(paths.relay));
        const fragile = isFragileAth10k(board, chipset);
        const fftAvailable = pathsOk && (chipset === "ath9k" || chipset === "ath10k");
        const surveyAvailable = chipset === "ath10k";
        const selectable = fftAvailable || surveyAvailable;
        const captureMode = captureModeForChipset(chipset, board);
        push(out, {
            iface: r.iface,
            phy: phy,
            chipset: chipset,
            mode: r.mode?.mode || "unknown",
            channel: channel,
            band: five ? "5GHz" : "other",
            fft_paths: pathsOk,
            fft_available: fftAvailable,
            survey_available: surveyAvailable,
            capture_mode: captureMode || (fftAvailable ? "fft" : (surveyAvailable ? "survey" : null)),
            prefer_survey: fragile && surveyAvailable,
            fft_opt_in: fragile && fftAvailable,
            fragile_ath10k: fragile,
            max_fft_sec: fragile ? ATH10K_FFT_MAX_SEC : SESSION_DEFAULT_SEC,
            capture_safe: selectable,
            selectable: selectable
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
    let anyCapture = !!(cap?.fft_available || cap?.survey_available ||
        (cap?.capture_mode === "fft") || (cap?.capture_mode === "survey"));
    if (!anyCapture) {
        for (let i = 0; i < length(rlist); i++) {
            if (rlist[i].selectable || radioHasFft(rlist[i]) || radioHasSurvey(rlist[i])) {
                anyCapture = true;
                break;
            }
        }
    }

    if (anyCapture) {
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
            message: `Waterfall is not available on this node: no FFT or survey path found (board looks like a focus device: ${board || "unknown"}).`
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
            fft_available: false,
            survey_available: false,
            capture_mode: null
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
    const pathsOk = hasCtl && hasRelay;
    const fragile = isFragileAth10k(board, chipset);
    const fftAvailable = pathsOk && (chipset === "ath9k" || chipset === "ath10k");
    const surveyAvailable = chipset === "ath10k";
    const captureSafe = fftAvailable || surveyAvailable;
    const captureMode = captureModeForChipset(chipset, board) ||
        (fftAvailable ? "fft" : (surveyAvailable ? "survey" : null));

    const rmode = radio.mode?.mode || "unknown";
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
        mode: rmode,
        channel: channel,
        bandwidth: radio.mode?.bandwidth ?? null,
        frequency_mhz: freq,
        band: five ? "5GHz" : "other",
        fft_available: fftAvailable,
        survey_available: surveyAvailable,
        capture_mode: captureMode,
        prefer_survey: fragile && surveyAvailable,
        fft_opt_in: fragile && fftAvailable,
        fragile_ath10k: fragile,
        max_fft_sec: fragile ? ATH10K_FFT_MAX_SEC : SESSION_MAX_SEC,
        fft_paths: pathsOk,
        capture_safe: captureSafe,
        spectral_ctl: hasCtl,
        spectral_relay: hasRelay,
        paths: paths,
        note: focusNote(chipset, fftAvailable, board, captureSafe, captureMode),
        radios: listRadios()
    };
    const sup = supportStatus(cap);
    cap.supported = sup.supported;
    cap.unsupported_message = sup.message;
    return cap;
};

/**
 * Channel/BW lists for the GUI (from AREDN radio config).
 * channel/bandwidth "all" means full band hop.
 */
export function getScanOptions(preferredIface)
{
    const radio = selectRadio(preferredIface);
    if (!radio || !radio.iface) {
        return {
            iface: null,
            current_channel: null,
            current_bandwidth: null,
            bandwidths: [],
            channels_by_bw: {},
            channels: []
        };
    }
    const curCh = radio.mode?.channel ?? null;
    const curBw = radio.mode?.bandwidth ?? null;
    const bws = radio.bws || hardware.getRfBandwidths(radio.iface) || [];
    const byBw = radio.channels || {};
    const bwKey = curBw != null ? `${curBw}` : (length(bws) ? `${bws[0]}` : "10");
    let channels = byBw[bwKey] || [];
    if (!length(channels)) {
        channels = hardware.getRfChannels(radio.iface) || [];
    }
    /* Prefer 5 GHz entries when present. */
    let filtered = [];
    for (let i = 0; i < length(channels); i++) {
        if (channels[i].frequency == null || channels[i].frequency >= 5000) {
            push(filtered, {
                number: channels[i].number,
                frequency: channels[i].frequency,
                label: channels[i].label || `${channels[i].number}`
            });
        }
    }
    if (!length(filtered)) {
        filtered = channels;
    }
    return {
        iface: radio.iface,
        current_channel: curCh,
        current_bandwidth: curBw,
        current_ssid: radio.mode?.ssid || null,
        bandwidths: bws,
        channels_by_bw: byBw,
        channels: filtered
    };
};

function channelListForBw(radio, bw)
{
    if (!radio) {
        return [];
    }
    const key = `${bw}`;
    let list = radio.channels ? (radio.channels[key] || []) : [];
    if (!length(list)) {
        list = hardware.getRfChannels(radio.iface) || [];
    }
    const out = [];
    for (let i = 0; i < length(list); i++) {
        if (list[i].frequency != null && list[i].frequency < 5000) {
            continue;
        }
        push(out, list[i]);
    }
    return length(out) ? out : list;
};

function freqSpanForChannel(iface, channel, bw)
{
    const f = hardware.getChannelFrequency(iface, channel);
    if (f == null || f < 0) {
        return null;
    }
    const half = (bw != null && bw > 0 ? bw : 20) / 2.0;
    return { f_start: f - half, f_stop: f + half, frequency: f };
};

/* GUI BW = waterfall plot width. Scan BW = widest radio BW that fits in the plot. */
function maxRadioBw(radio)
{
    const bws = radio.bws || hardware.getRfBandwidths(radio.iface) || [];
    let m = 0;
    for (let i = 0; i < length(bws); i++) {
        if (bws[i] != null && bws[i] > m) {
            m = bws[i];
        }
    }
    return m > 0 ? m : 20;
};

function widestScanBw(radio, plotWidthMhz)
{
    const cap = plotWidthMhz != null && plotWidthMhz > 0 ? plotWidthMhz : 10000;
    const bws = radio.bws || hardware.getRfBandwidths(radio.iface) || [];
    let best = 0;
    for (let i = 0; i < length(bws); i++) {
        const b = bws[i];
        if (b != null && b <= cap && b > best) {
            best = b;
        }
    }
    if (best > 0) {
        return best;
    }
    const m = maxRadioBw(radio);
    return m <= cap ? m : cap;
};

/* Prefer hop centers spaced ~scanBw apart (AREDN's 80 list may still be 40-spaced). */
function thinHopsBySpacing(hops, minSpacingMhz)
{
    if (!hops || !length(hops)) {
        return [];
    }
    const space = minSpacingMhz != null && minSpacingMhz > 0 ? minSpacingMhz : 20;
    const out = [];
    let lastF = null;
    for (let i = 0; i < length(hops); i++) {
        const h = hops[i];
        if (h == null || h.frequency == null) {
            continue;
        }
        if (lastF == null || (h.frequency - lastF) >= (space * 0.75)) {
            push(out, h);
            lastF = h.frequency;
        }
    }
    if (!length(out)) {
        push(out, hops[0]);
    }
    /* Always include last so the top of the band is covered. */
    const last = hops[length(hops) - 1];
    if (length(out) && last && last.frequency != null &&
        out[length(out) - 1].frequency !== last.frequency) {
        push(out, last);
    }
    return out;
};

function channelNearFrequency(radio, freqMhz, fallbackCh)
{
    if (freqMhz == null) {
        return fallbackCh;
    }
    let best = null;
    let bestDist = null;
    const bws = radio.bws || [5, 10, 20, 40, 80];
    for (let bi = 0; bi < length(bws); bi++) {
        const list = channelListForBw(radio, bws[bi]);
        for (let i = 0; i < length(list); i++) {
            const h = list[i];
            if (h == null || h.frequency == null || h.number == null) {
                continue;
            }
            const d = h.frequency > freqMhz ? (h.frequency - freqMhz) : (freqMhz - h.frequency);
            if (bestDist == null || d < bestDist) {
                bestDist = d;
                best = h.number;
            }
        }
    }
    return best != null ? best : fallbackCh;
}

/**
 * Cover [plotF0, plotF1] with listen windows of width scanBw (no frequency stretch).
 * Centers spaced by scanBw; channel numbers are nearest legal channels for retune.
 */
function sectionsCoveringPlot(radio, plotF0, plotF1, scanBw, anchorCh, anchorFreq)
{
    const out = [];
    if (plotF0 == null || plotF1 == null || plotF1 <= plotF0) {
        return out;
    }
    const bw = scanBw != null && scanBw > 0 ? scanBw : 20;
    const half = bw / 2.0;
    const span = plotF1 - plotF0;
    if (span <= bw + 0.5) {
        const f = anchorFreq != null ? anchorFreq : ((plotF0 + plotF1) / 2.0);
        push(out, {
            number: channelNearFrequency(radio, f, anchorCh),
            frequency: f
        });
        return out;
    }
    /* Prefer real channels whose listen window overlaps the plot. */
    let list = channelListForBw(radio, bw);
    if (!length(list)) {
        list = channelListForBw(radio, 20);
    }
    if (!length(list)) {
        list = channelListForBw(radio, 10);
    }
    const overlapping = [];
    for (let i = 0; i < length(list); i++) {
        const h = list[i];
        if (h == null || h.frequency == null) {
            continue;
        }
        if ((h.frequency + half) >= plotF0 && (h.frequency - half) <= plotF1) {
            push(overlapping, h);
        }
    }
    let hop = thinHopsBySpacing(overlapping, bw);
    if (!length(hop)) {
        /* Geometric centers if channel list is sparse. */
        let center = plotF0 + half;
        const lastCenter = plotF1 - half;
        while (center <= lastCenter + 0.05) {
            push(hop, {
                number: channelNearFrequency(radio, center, anchorCh),
                frequency: center
            });
            center = center + bw;
        }
        if (!length(hop)) {
            push(hop, {
                number: anchorCh,
                frequency: anchorFreq != null ? anchorFreq : ((plotF0 + plotF1) / 2.0)
            });
        }
    }
    return hop;
}

/**
 * Resolve GUI channel/bw ("all" or numbers) into a capture plan.
 * bandwidth / plot width = what the waterfall axis shows.
 * scan_bandwidth = widest RF BW used while hopping (≤ plot width).
 * If plot wider than one listen, sections stitch side-by-side (no stretch).
 */
export function resolveScanPlan(preferredIface, channelSel, bandwidthSel)
{
    const radio = selectRadio(preferredIface);
    const opts = getScanOptions(preferredIface);
    if (!radio || !radio.iface) {
        return { ok: false, error: "No radio" };
    }
    const iface = radio.iface;
    const curCh = opts.current_channel;
    const curBw = opts.current_bandwidth || 10;
    let wantAllCh = channelSel === "all" || channelSel === "ALL";
    let wantAllBw = bandwidthSel === "all" || bandwidthSel === "ALL";
    if (wantAllCh) {
        wantAllBw = true;
    }
    if (wantAllBw) {
        wantAllCh = true;
    }

    let plotBw = curBw;
    if (!wantAllBw && bandwidthSel != null && bandwidthSel !== "" && bandwidthSel !== "current") {
        plotBw = int(bandwidthSel);
    }
    if (plotBw == null || plotBw <= 0) {
        plotBw = 10;
    }

    if (wantAllCh) {
        /* Full-band plot; scan at widest radio BW (e.g. 80) to cover faster. */
        const dense = channelListForBw(radio, length(channelListForBw(radio, 5)) ? 5 : 10);
        const scanBw = widestScanBw(radio, 10000);
        let hop = channelListForBw(radio, scanBw);
        if (!length(hop)) {
            hop = channelListForBw(radio, 40);
        }
        if (!length(hop)) {
            hop = channelListForBw(radio, 20);
        }
        hop = thinHopsBySpacing(hop, scanBw);
        if (!length(dense) && !length(hop)) {
            return { ok: false, error: "No channels available for ALL scan" };
        }
        const use = length(dense) ? dense : hop;
        const first = use[0];
        const last = use[length(use) - 1];
        const halfPlot = (length(dense) ? 10 : scanBw) / 2.0;
        return {
            ok: true,
            mode: "all",
            iface: iface,
            ssid: opts.current_ssid,
            restore_channel: curCh,
            restore_bandwidth: curBw,
            restore_freq: hardware.getChannelFrequency(iface, curCh),
            bandwidth: "all",
            plot_bandwidth: null,
            scan_bandwidth: scanBw,
            channel: "all",
            hop_channels: hop,
            sections: hop,
            section_count: length(hop),
            f_start: first.frequency - halfPlot,
            f_stop: last.frequency + halfPlot
        };
    }

    let ch = curCh;
    if (channelSel != null && channelSel !== "" && channelSel !== "current") {
        ch = int(channelSel);
    }
    const scanBw = widestScanBw(radio, plotBw);
    const span = freqSpanForChannel(iface, ch, plotBw);
    if (!span) {
        return { ok: false, error: `Cannot resolve frequency for channel ${ch}` };
    }
    const hop = sectionsCoveringPlot(radio, span.f_start, span.f_stop, scanBw, ch, span.frequency);
    const nSec = length(hop) > 0 ? length(hop) : 1;
    const sameOne =
        nSec === 1 &&
        ch === curCh &&
        scanBw === curBw &&
        plotBw === curBw;
    return {
        ok: true,
        mode: sameOne ? "current" : (nSec > 1 ? "stitch" : "single"),
        iface: iface,
        ssid: opts.current_ssid,
        restore_channel: curCh,
        restore_bandwidth: curBw,
        restore_freq: hardware.getChannelFrequency(iface, curCh),
        channel: ch,
        bandwidth: plotBw,
        plot_bandwidth: plotBw,
        scan_bandwidth: scanBw,
        hop_channels: hop,
        sections: hop,
        section_count: nSec,
        f_start: span.f_start,
        f_stop: span.f_stop,
        frequency: span.frequency
    };
};

const SECTION_RETUNE_SEC = 3;
const SECTION_RESTORE_SEC = 12;

function planSections(plan)
{
    const scanBw = plan.scan_bandwidth != null ? plan.scan_bandwidth : 20;
    const half = scanBw / 2.0;
    const src = plan.sections || plan.hop_channels || [];
    const out = [];
    for (let i = 0; i < length(src); i++) {
        const h = src[i];
        if (h == null || h.frequency == null) {
            continue;
        }
        push(out, {
            number: h.number,
            frequency: h.frequency,
            f_start: h.frequency - half,
            f_stop: h.frequency + half
        });
    }
    return out;
};

function estimateSessionSec(sectionCount, sectionDurSec)
{
    const n = sectionCount > 0 ? sectionCount : 1;
    const d = sectionDurSec > 0 ? sectionDurSec : 30;
    return n * (d + SECTION_RETUNE_SEC) + SECTION_RESTORE_SEC;
};

/* Mesh-safe retune: never leave IBSS without an immediate join.
 * Prefer leave→join (fast); fall back to UCI + wifi reload; always verify. */
function iwBwToken(bw)
{
    if (bw === 5) {
        return "5MHz";
    }
    if (bw === 10) {
        return "10MHz";
    }
    if (bw === 40) {
        return "HT40+";
    }
    if (bw === 80) {
        return "80MHz";
    }
    return "HT20";
};

function readLiveChannelInfo(iface)
{
    if (!iface) {
        return null;
    }
    system(`iw dev ${iface} info >/tmp/waterfall-iwdev.txt 2>/dev/null`);
    let text = "";
    try {
        text = fs.readfile("/tmp/waterfall-iwdev.txt") || "";
    }
    catch (_) {
        text = "";
    }
    let m = match(text, /channel\s+([0-9]+)\s*\(([0-9]+)\s*MHz\)/);
    if (m) {
        return { channel: int(m[1]), frequency: int(m[2]) };
    }
    system(`iwinfo ${iface} info >/tmp/waterfall-iwinfo.txt 2>/dev/null`);
    try {
        text = fs.readfile("/tmp/waterfall-iwinfo.txt") || "";
    }
    catch (_) {
        text = "";
    }
    m = match(text, /Channel:\s*([0-9]+)\s*\(([0-9]+)\.([0-9]+)\s*GHz\)/);
    if (m) {
        const ch = int(m[1]);
        const mhz = int(m[2]) * 1000 + int(m[3]);
        return { channel: ch, frequency: mhz };
    }
    m = match(text, /Channel:\s*([0-9]+)\s*\(([0-9.]+)\s*GHz\)/);
    if (m) {
        return { channel: int(m[1]), frequency: int(m[2] * 1000) };
    }
    return null;
};

function freqClose(a, b, tol)
{
    if (a == null || b == null) {
        return false;
    }
    let d = a - b;
    if (d < 0) {
        d = -d;
    }
    return d <= (tol != null ? tol : 5);
};

function retuneViaWifiReload(iface, channel, bandwidth, waitSec)
{
    const dev = hardware.getRadioDevice(iface);
    if (!dev) {
        return false;
    }
    if (channel != null && `${channel}` !== "" && `${channel}` !== "all") {
        system(`uci set wireless.${dev}.channel=${int(channel)} >/dev/null 2>&1`);
    }
    if (bandwidth != null && bandwidth > 0) {
        system(`uci set wireless.${dev}.chanbw=${int(bandwidth)} >/dev/null 2>&1`);
    }
    system("/sbin/wifi reload >/dev/null 2>&1");
    const w = waitSec != null ? waitSec : 10;
    system(`sleep ${w}`);
    return true;
};

function retuneIbssLeaveJoin(iface, ssid, freqMhz, bw)
{
    if (!iface || !ssid || freqMhz == null || freqMhz <= 0) {
        return false;
    }
    if (match(ssid, /['\\$`]/)) {
        return false;
    }
    const tok = iwBwToken(bw || 10);
    /* leave then join in one shell so we never stop after leave alone */
    system(`iw dev ${iface} ibss leave >/dev/null 2>&1; iw dev ${iface} ibss join '${ssid}' ${int(freqMhz)} ${tok} fixed-freq >/dev/null 2>&1`);
    system("sleep 2");
    return true;
};

/**
 * Retune and verify the live channel/freq. Returns { ok, method, channel, frequency, error }.
 */
function retuneVerified(iface, ssid, channel, freqMhz, bw, opts)
{
    opts = opts || {};
    const reloadWait = opts.reloadWait != null ? opts.reloadWait : 10;
    if (ssid && freqMhz != null) {
        retuneIbssLeaveJoin(iface, ssid, freqMhz, bw);
        let info = readLiveChannelInfo(iface);
        if (info && (info.channel === int(channel) || freqClose(info.frequency, freqMhz))) {
            return { ok: true, method: "ibss", channel: info.channel, frequency: info.frequency };
        }
    }
    retuneViaWifiReload(iface, channel, bw, reloadWait);
    let info = readLiveChannelInfo(iface);
    if (info && (info.channel === int(channel) || freqClose(info.frequency, freqMhz))) {
        return { ok: true, method: "wifi", channel: info.channel, frequency: info.frequency };
    }
    return {
        ok: false,
        method: null,
        channel: info ? info.channel : null,
        frequency: info ? info.frequency : null,
        error: "retune not verified on live iface"
    };
};

function restoreVerified(iface, ssid, channel, freqMhz, bw)
{
    const r = retuneVerified(iface, ssid, channel, freqMhz, bw, { reloadWait: 12 });
    if (r.ok) {
        return r;
    }
    /* Emergency: bounce wifi from UCI config */
    const dev = hardware.getRadioDevice(iface);
    if (dev && channel != null) {
        system(`uci set wireless.${dev}.channel=${int(channel)} >/dev/null 2>&1`);
        if (bw != null) {
            system(`uci set wireless.${dev}.chanbw=${int(bw)} >/dev/null 2>&1`);
        }
    }
    system("/sbin/wifi down >/dev/null 2>&1");
    system("sleep 2");
    system("/sbin/wifi up >/dev/null 2>&1");
    system("sleep 12");
    const info = readLiveChannelInfo(iface);
    if (info && (info.channel === int(channel) || freqClose(info.frequency, freqMhz))) {
        return { ok: true, method: "wifi-up", channel: info.channel, frequency: info.frequency };
    }
    return {
        ok: false,
        method: "wifi-up",
        channel: info ? info.channel : null,
        frequency: info ? info.frequency : null,
        error: "restore not verified — node may need reboot"
    };
};

function thinHops(hops, maxN)
{
    const n = length(hops);
    if (n <= 0 || maxN <= 0) {
        return [];
    }
    if (n <= maxN) {
        return hops;
    }
    const out = [];
    if (maxN === 1) {
        push(out, hops[int(n / 2)]);
        return out;
    }
    for (let i = 0; i < maxN; i++) {
        const idx = int((i * (n - 1)) / (maxN - 1));
        push(out, hops[idx]);
    }
    return out;
};

function bandBinCount(f0, f1)
{
    if (f0 == null || f1 == null || f1 <= f0) {
        return TARGET_BINS;
    }
    const span = f1 - f0;
    if (span >= 200) {
        return 256;
    }
    if (span >= 40) {
        return 128;
    }
    return TARGET_BINS;
};

function placeBinsOnBand(bins, sampleF0, sampleF1, bandF0, bandF1, nOut)
{
    const out = [];
    for (let i = 0; i < nOut; i++) {
        push(out, 0);
    }
    if (!bins || !length(bins) || bandF1 <= bandF0) {
        return out;
    }
    if (sampleF0 == null || sampleF1 == null || sampleF1 <= sampleF0) {
        /* Refuse to invent a frequency span — no stretch onto the plot. */
        return out;
    }
    const n = length(bins);
    const span = sampleF1 - sampleF0;
    const bandSpan = bandF1 - bandF0;
    for (let i = 0; i < n; i++) {
        const fc = sampleF0 + (i + 0.5) * (span / n);
        if (fc < bandF0 || fc > bandF1) {
            continue;
        }
        let idx = int(((fc - bandF0) / bandSpan) * nOut);
        if (idx < 0) {
            idx = 0;
        }
        if (idx >= nOut) {
            idx = nOut - 1;
        }
        if (bins[i] > out[idx]) {
            out[idx] = bins[i];
        }
    }
    return out;
};

function axisChannelsForPlan(plan)
{
    const out = [];
    if (!plan || !plan.ok) {
        return out;
    }
    const hops = plan.hop_channels || [];
    for (let i = 0; i < length(hops); i++) {
        if (hops[i].number == null || hops[i].frequency == null) {
            continue;
        }
        push(out, { number: hops[i].number, frequency: hops[i].frequency });
    }
    return out;
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

/* ath10k often reports noise=0 on unused channels; that is not a real floor. */
function surveyNoiseValid(noise)
{
    return noise != null && noise < -20;
};

function emptyBinRow(n)
{
    const out = [];
    for (let i = 0; i < n; i++) {
        push(out, 0);
    }
    return out;
};

function mergeBinMax(dst, src)
{
    if (!dst || !src) {
        return dst;
    }
    const n = length(dst) < length(src) ? length(dst) : length(src);
    for (let i = 0; i < n; i++) {
        if (src[i] > dst[i]) {
            dst[i] = src[i];
        }
    }
    return dst;
};

function paintBinAtFreq(bins, freq, value, bandF0, bandF1)
{
    if (!bins || freq == null || bandF1 <= bandF0 || value <= 0) {
        return;
    }
    const nOut = length(bins);
    let idx = int(((freq - bandF0) / (bandF1 - bandF0)) * nOut);
    if (idx < 0) {
        idx = 0;
    }
    if (idx >= nOut) {
        idx = nOut - 1;
    }
    if (value > bins[idx]) {
        bins[idx] = value;
    }
    const soft = int(value * 0.6);
    if (idx > 0 && bins[idx - 1] < soft) {
        bins[idx - 1] = soft;
    }
    if (idx + 1 < nOut && bins[idx + 1] < soft) {
        bins[idx + 1] = soft;
    }
};

/**
 * Band activity from survey: valid noise as a quiet floor, plus per-interval
 * busy-time deltas so repeated dumps are not identical copies.
 * amplify (default true): stretch noise into a visible range and gain-boost
 * tiny busy fractions (ath10k off-channel counters are often frozen).
 * Returns { bins, prev } where prev is the freq→counters map for the next sample.
 */
function surveyActivityToBins(iface, prevByFreq, nOut, bandF0, bandF1, amplify)
{
    const rows = getSurveySummary(iface);
    const next = {};
    const bins = emptyBinRow(nOut);
    const amp = amplify != false;
    /* Quiet noise floor → 0..noiseMax; busy deltas can still exceed that. */
    const noiseMax = amp ? 70 : 30;
    const busyGain = amp ? 40 : 1;
    if (bandF0 == null || bandF1 == null || bandF1 <= bandF0) {
        return { bins: bins, prev: next };
    }
    for (let i = 0; i < length(rows); i++) {
        const r = rows[i];
        const freq = r.frequency;
        if (freq == null || freq < bandF0 || freq > bandF1) {
            continue;
        }
        next[`${freq}`] = {
            noise: r.noise,
            time: r.time,
            time_busy: r.time_busy
        };
        let v = 0;
        if (surveyNoiseValid(r.noise)) {
            v = int((r.noise + 120) * noiseMax / 60);
            if (v < 0) {
                v = 0;
            }
            if (v > noiseMax) {
                v = noiseMax;
            }
        }
        if (prevByFreq) {
            const prev = prevByFreq[`${freq}`];
            if (prev && r.time != null && prev.time != null && r.time_busy != null && prev.time_busy != null) {
                const dt = r.time - prev.time;
                const db = r.time_busy - prev.time_busy;
                if (dt > 0 && db >= 0) {
                    let busyV = int((db * 100 * busyGain) / dt);
                    if (busyV > 100) {
                        busyV = 100;
                    }
                    /* Tiny mesh busy fractions often round to 0 without a floor. */
                    if (amp && db > 0 && busyV < 10) {
                        busyV = 10;
                    }
                    if (busyV > v) {
                        v = busyV;
                    }
                }
            }
        }
        paintBinAtFreq(bins, freq, v, bandF0, bandF1);
    }
    return { bins: bins, prev: next };
};

/**
 * Build one heatmap sweep from nl80211 survey dump (ath10k-safe path).
 * Bin intensity = valid noise floor, blended with channel busy fraction when present.
 */
export function surveyToSweep(iface, nBins)
{
    const rows = getSurveySummary(iface);
    const usable = [];
    for (let i = 0; i < length(rows); i++) {
        const r = rows[i];
        if (r.frequency == null) {
            continue;
        }
        if (!surveyNoiseValid(r.noise) && (r.time == null || r.time <= 0)) {
            continue;
        }
        push(usable, r);
    }
    if (!length(usable)) {
        return null;
    }
    let five = [];
    for (let i = 0; i < length(usable); i++) {
        if (usable[i].frequency >= 5000) {
            push(five, usable[i]);
        }
    }
    const use = length(five) ? five : usable;
    let fMin = use[0].frequency;
    let fMax = use[0].frequency;
    for (let i = 1; i < length(use); i++) {
        if (use[i].frequency < fMin) {
            fMin = use[i].frequency;
        }
        if (use[i].frequency > fMax) {
            fMax = use[i].frequency;
        }
    }
    if (fMax <= fMin) {
        fMax = fMin + 20;
    }
    const nb = nBins != null && nBins > 0 ? nBins : bandBinCount(fMin, fMax);
    const bins = emptyBinRow(nb);
    for (let i = 0; i < length(use); i++) {
        const r = use[i];
        let v = 0;
        if (surveyNoiseValid(r.noise)) {
            v = int((r.noise + 120) * 100 / 60);
            if (v < 0) {
                v = 0;
            }
            if (v > 100) {
                v = 100;
            }
        }
        if (r.time != null && r.time > 0 && r.time_busy != null) {
            const busy = int((r.time_busy * 80) / r.time);
            if (busy > v) {
                v = busy > 100 ? 100 : busy;
            }
        }
        paintBinAtFreq(bins, r.frequency, v, fMin, fMax);
    }
    return {
        f_start: fMin,
        f_stop: fMax,
        noise: use[0].noise,
        bins: bins,
        source: "survey"
    };
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

function emptyCache(iface)
{
    return {
        ok: true,
        version: packageVersion(),
        have_cache: false,
        pending: false,
        sweeps: [],
        times: [],
        meta: iface ? { iface: iface } : null,
        iface: iface || null,
        slot: 0
    };
}

function pendingCache(iface)
{
    return {
        ok: true,
        version: packageVersion(),
        have_cache: false,
        pending: true,
        sweeps: [],
        times: [],
        meta: {
            iface: iface || null,
            pending: true,
            note: "New scan in process"
        },
        iface: iface || null,
        slot: 0
    };
}

function clampCacheSlot(slot)
{
    let s = int(slot);
    if (s != s || s < 0) {
        return 0;
    }
    if (s > CACHE_HISTORY_SLOTS) {
        return CACHE_HISTORY_SLOTS;
    }
    return s;
};

function cachePathForIface(iface, slot)
{
    const s = clampCacheSlot(slot == null ? 0 : slot);
    if (!iface || !match(iface, /^[a-zA-Z0-9]+$/)) {
        return s === 0 ? CACHE_JSON : `${CACHE_JSON}.${s}`;
    }
    if (s === 0) {
        return `${CACHE_PREFIX}${iface}.json`;
    }
    return `${CACHE_PREFIX}${iface}.${s}.json`;
}

function moveCachePath(src, dst)
{
    if (src === dst) {
        return;
    }
    try {
        fs.unlink(dst);
    }
    catch (_) {
    }
    if (!fs.access(src)) {
        return;
    }
    try {
        const data = fs.readfile(src);
        if (data != null) {
            fs.writefile(dst, data);
        }
        fs.unlink(src);
    }
    catch (_) {
        system(`mv -f '${src}' '${dst}' 2>/dev/null`);
    }
};

/* One-shot: pull any 0.2.37 flash caches into /tmp, then drop the flash dir. */
function migrateFlashCacheToTmp(iface, slot)
{
    const dst = cachePathForIface(iface, slot);
    if (fs.access(dst)) {
        return;
    }
    let src;
    const s = clampCacheSlot(slot == null ? 0 : slot);
    if (!iface || !match(iface, /^[a-zA-Z0-9]+$/)) {
        src = s === 0 ? `${CACHE_FLASH_DIR}/waterfall-cache.json` : `${CACHE_FLASH_DIR}/waterfall-cache.json.${s}`;
    }
    else if (s === 0) {
        src = `${CACHE_FLASH_DIR}/waterfall-cache-${iface}.json`;
    }
    else {
        src = `${CACHE_FLASH_DIR}/waterfall-cache-${iface}.${s}.json`;
    }
    if (fs.access(src)) {
        moveCachePath(src, dst);
    }
};

export function clampDuration(durationSec)
{
    let d = int(durationSec);
    if (d != d || d <= 0) {
        return SESSION_DEFAULT_SEC;
    }
    if (d > SESSION_MAX_SEC) {
        return SESSION_MAX_SEC;
    }
    return d;
};

export function allowedDurations()
{
    /* 60s covers both "60s" and "1m"; longer runs space sweeps to cap RAM */
    return [5, 10, 15, 30, 60, 300, 600];
};

function summarizeCacheSlot(iface, slot, cache)
{
    const m = cache?.meta || {};
    const have = !!(cache && cache.have_cache);
    const pending = !!(cache && cache.pending);
    let fallback = "Current";
    if (slot === 1) {
        fallback = "Previous";
    }
    else if (slot === 2) {
        fallback = "−2";
    }
    else if (slot === 3) {
        fallback = "−3";
    }
    return {
        slot: slot,
        have_cache: have,
        pending: pending,
        enabled: have && !pending,
        label: fallback,
        started_at: m.started_at ?? null,
        ended_at: m.ended_at ?? null,
        scan_channel: m.scan_channel ?? null,
        plot_bandwidth: m.plot_bandwidth ?? null,
        capture_mode: m.capture_mode ?? null,
        sweep_count: m.sweep_count ?? length(cache?.sweeps || []),
        iface: cache?.iface || iface || null
    };
};

export function readCache(iface, slot)
{
    const s = clampCacheSlot(slot == null ? 0 : slot);
    migrateFlashCacheToTmp(iface, s);
    let path = cachePathForIface(iface, s);
    if (s === 0 && !fs.access(path) && iface && fs.access(CACHE_JSON)) {
        try {
            const legacy = json(fs.readfile(CACHE_JSON));
            if (legacy?.meta?.iface === iface) {
                path = CACHE_JSON;
            }
            else if (!iface) {
                path = CACHE_JSON;
            }
        }
        catch (_) {
        }
    }
    if (!fs.access(path)) {
        const e = emptyCache(iface);
        e.slot = s;
        return e;
    }
    try {
        const c = json(fs.readfile(path));
        c.ok = true;
        c.pending = !!(c.pending || c.meta?.pending);
        c.have_cache = !c.pending && length(c.sweeps || []) > 0;
        c.version = packageVersion();
        c.iface = c.meta?.iface || iface || null;
        c.slot = s;
        return c;
    }
    catch (_) {
        return {
            ok: false,
            error: "Corrupt waterfall cache",
            have_cache: false,
            pending: false,
            sweeps: [],
            version: packageVersion(),
            iface: iface || null,
            slot: s
        };
    }
};

export function writeCache(cache)
{
    const iface = cache?.meta?.iface || cache?.iface || null;
    const slot = clampCacheSlot(cache?.slot == null ? 0 : cache.slot);
    const path = cachePathForIface(iface, slot);
    cache.slot = slot;
    fs.writefile(path, sprintf("%J", cache));
};

export function listCacheSlots(iface)
{
    const out = [];
    for (let s = 0; s <= CACHE_HISTORY_SLOTS; s++) {
        push(out, summarizeCacheSlot(iface, s, readCache(iface, s)));
    }
    return out;
};

/**
 * On Start: Current → Previous → −2 → −3 (drop oldest). Current becomes pending.
 * Empty/pending Current is not pushed into history.
 */
export function rotateCacheForNewScan(iface)
{
    if (!iface || !match(iface, /^[a-zA-Z0-9]+$/)) {
        return { ok: false, error: "iface required" };
    }
    const cur = readCache(iface, 0);
    if (cur.have_cache && !cur.pending) {
        const drop = cachePathForIface(iface, CACHE_HISTORY_SLOTS);
        try {
            fs.unlink(drop);
        }
        catch (_) {
        }
        for (let s = CACHE_HISTORY_SLOTS - 1; s >= 0; s--) {
            moveCachePath(cachePathForIface(iface, s), cachePathForIface(iface, s + 1));
        }
    }
    else {
        try {
            fs.unlink(cachePathForIface(iface, 0));
        }
        catch (_) {
        }
    }
    const pending = pendingCache(iface);
    writeCache(pending);
    persistLog(`cache rotate iface=${iface}`);
    return { ok: true, slots: listCacheSlots(iface) };
};

function isCacheFilename(name)
{
    return !!match(name, /^waterfall-cache(-[a-zA-Z0-9]+)?(\.[1-3])?\.json$/);
};

function collectCacheFilesInDir(dir, out)
{
    if (!fs.access(dir)) {
        return;
    }
    const names = fs.lsdir(dir) || [];
    for (let i = 0; i < length(names); i++) {
        const name = names[i];
        if (!isCacheFilename(name)) {
            continue;
        }
        const path = `${dir}/${name}`;
        const st = fs.stat(path);
        push(out, {
            name: name,
            path: path,
            bytes: st ? int(st.size) : 0
        });
    }
};

export function listCacheFiles()
{
    const out = [];
    collectCacheFilesInDir("/tmp", out);
    /* Legacy flash caches from 0.2.37 — Clear / upgrade should free them. */
    collectCacheFilesInDir(CACHE_FLASH_DIR, out);
    return out;
};

export function cacheDiskUsage()
{
    const files = listCacheFiles();
    let bytes = 0;
    for (let i = 0; i < length(files); i++) {
        bytes += files[i].bytes;
    }
    return {
        ok: true,
        bytes: bytes,
        files: length(files),
        caches: files
    };
};

export function clearAllCaches()
{
    const files = listCacheFiles();
    let freed = 0;
    let removed = 0;
    for (let i = 0; i < length(files); i++) {
        freed += files[i].bytes;
        try {
            fs.unlink(files[i].path);
            removed++;
        }
        catch (_) {
        }
    }
    system(`rm -rf ${CACHE_FLASH_DIR} 2>/dev/null`);
    persistLog(`cache clear removed=${removed} freed=${freed}`);
    return {
        ok: true,
        freed_bytes: freed,
        removed: removed,
        have_cache: false,
        cache_bytes: 0,
        cache_files: 0,
        cache_slots: []
    };
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
 * One-shot capture. ath9k: inline FFT. ath10k: survey by default on fragile
 * QCA988x; FFT only when allowFft is true.
 */
export function captureSpectral(preferredIface, allowFft)
{
    const cap = probeCapability(preferredIface);
    if (!cap.ok) {
        return cap;
    }
    if (!cap.capture_safe || !cap.capture_mode) {
        return {
            ok: false,
            error: "No waterfall capture path on this radio",
            capability: cap
        };
    }

    if (cap.chipset === "ath10k") {
        const tryFft = !!allowFft && !!cap.fft_available && !spectralCooldownActive();
        let modeUsed = "fft";
        let sweep = null;
        let error = null;
        let bytes = 0;
        let recovered = false;

        beginScanHold({ iface: cap.iface, mode: tryFft ? "fft" : "survey", at: nowSec() });
        try {
            if (tryFft) {
                const pulse = runAth10kFftPulse(cap.iface, cap.phy, false);
                bytes = pulse.bytes;
                recovered = pulse.recovered;
                if (pulse.ok) {
                    const buf = readFftBuffer(FFT_OUT);
                    if (buf) {
                        sweep = samplesToSweep(parseFftTlvs(buf, 24));
                    }
                    if (!sweep) {
                        error = "FFT bytes present but TLV parse failed";
                    }
                }
                else {
                    error = pulse.error;
                }
            }
            else if (spectralCooldownActive() && allowFft) {
                error = "spectral cooldown active after prior failure";
            }

            if (!sweep && cap.survey_available) {
                modeUsed = "survey";
                sweep = surveyToSweep(cap.iface);
                if (sweep) {
                    error = recovered
                        ? "FFT timed out; using survey (disable-only recover)"
                        : (allowFft && error ? `${error}; using survey` : null);
                }
                else if (!error) {
                    error = "No survey samples (empty nl80211 survey dump)";
                }
            }
            else if (!tryFft && !cap.survey_available) {
                error = "Survey unavailable and FFT not enabled";
            }
        }
        catch (e) {
            error = `${e}`;
        }
        disableAllSpectral();
        endScanHold("capture");

        return {
            ok: !!sweep,
            error: sweep ? error : (error || "No FFT or survey samples"),
            capability: cap,
            fft_file: modeUsed === "fft" ? FFT_OUT : null,
            fft_bytes: bytes,
            sweep: sweep,
            survey: getSurveySummary(cap.iface),
            experimental: modeUsed === "fft",
            capture_mode: modeUsed,
            recovered: recovered
        };
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
    writeSpectralCount(cap.paths, SPECTRAL_COUNT_DEFAULT);
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
        experimental: false,
        capture_mode: "fft"
    };
};

/**
 * Bounded RF session: dense time rows (Y = time).
 * GUI duration = listen time per section. Total wall time ≈ N×(section + retune) + restore.
 * ALL/multi = verified retune→listen section→next→restore.
 */
export function runSession(preferredIface, durationSec, channelSel, bandwidthSel, allowFft, amplifySurvey)
{
    let sectionDur = clampDuration(durationSec);
    const sleepSec = sectionDur >= 300 ? 1 : 0;
    fs.unlink(SESSION_STOP);

    const cap = probeCapability(preferredIface);
    /* UI startSessionAsync already rotates + writes pending; do not rotate twice. */
    if (cap.ok && cap.iface) {
        const cur = readCache(cap.iface, 0);
        if (!cur.pending) {
            rotateCacheForNewScan(cap.iface);
        }
    }
    const plan = resolveScanPlan(preferredIface, channelSel, bandwidthSel);
    const sections = plan.ok ? planSections(plan) : [];
    const sectionCount = length(sections) > 0 ? length(sections) : 1;
    const scanBw = plan.ok && plan.scan_bandwidth != null ? plan.scan_bandwidth : 20;
    const fragile = !!cap.fragile_ath10k;
    /* Survey contrast boost: default on; pass amplifySurvey=false / --no-amplify to disable. */
    const amplify = amplifySurvey == null ? true : !!amplifySurvey;
    const useSurveyDefault = fragile && !allowFft;
    /* Opt-in FFT on fragile: current-channel only, short, no ALL/stitch hops. */
    const useFragileFft = fragile && !!allowFft && !!cap.fft_available;
    if (useFragileFft && sectionDur > ATH10K_FFT_MAX_SEC) {
        sectionDur = ATH10K_FFT_MAX_SEC;
    }
    if (useSurveyDefault || (useFragileFft && plan.ok && (plan.mode === "all" || plan.mode === "stitch" || sectionCount > 1))) {
        /* Wide scans on QCA9887: survey only (no IBSS retune, no spectral). */
    }
    const preferAth9kChanscan =
        !!cap.ok &&
        cap.chipset === "ath9k" &&
        !!cap.fft_available &&
        plan.ok &&
        (plan.mode === "all" || plan.mode === "stitch" || sectionCount > 1);
    const progressSections = (useSurveyDefault || useFragileFft) ? 1 :
        (preferAth9kChanscan ? 1 : sectionCount);
    const totalEst = (useSurveyDefault || useFragileFft)
        ? (sectionDur + 3)
        : (preferAth9kChanscan
            ? (sectionDur + SECTION_RESTORE_SEC)
            : estimateSessionSec(sectionCount, sectionDur));
    const started = nowSec();
    const startedFrac = nowFrac();
    let ends = started + totalEst;
    let endsFrac = startedFrac + totalEst;
    const sweeps = [];
    const times = [];
    let mode = useSurveyDefault ? "survey" : (useFragileFft ? "fft" : cap.capture_mode);
    let usedSurveyFallback = false;
    let recovered = false;
    let retuned = false;
    let scanNote = null;
    let sectionIndex = 0;
    let usedAth9kChanscan = false;

    beginScanHold({
        iface: cap.iface,
        mode: mode,
        allow_fft: !!allowFft,
        fragile: fragile,
        at: started
    });
    petHardwareWatchdog();

    function publishSession(extra)
    {
        const now = nowSec();
        const st = {
            running: true,
            started_at: started,
            ends_at: ends,
            duration_sec: totalEst,
            section_duration_sec: sectionDur,
            section_count: preferAth9kChanscan ? progressSections : sectionCount,
            section_index: sectionIndex,
            section_ends_at: extra && extra.section_ends_at != null ? extra.section_ends_at : null,
            section_remaining_sec: null,
            scan_bandwidth: scanBw,
            plot_bandwidth: plan.ok ? plan.plot_bandwidth : null,
            iface: cap.iface,
            chipset: cap.chipset,
            capture_mode: mode,
            scan_channel: plan.ok ? plan.channel : null,
            scan_mode: plan.ok ? plan.mode : null,
            version: packageVersion(),
            server_now: now,
            remaining_sec: ends > now ? ends - now : 0
        };
        if (st.section_ends_at != null) {
            st.section_remaining_sec = st.section_ends_at > now ? st.section_ends_at - now : 0;
        }
        writeSessionState(st);
    }

    publishSession({});

    let error = null;
    let fStart = plan.ok ? plan.f_start : null;
    let fStop = plan.ok ? plan.f_stop : null;
    const bandF0 = fStart;
    const bandF1 = fStop;
    const nBins = bandBinCount(bandF0, bandF1);

    function pushRow(bins, f0, f1, tVal)
    {
        if (!bins || !length(bins)) {
            return;
        }
        if (bandF0 == null || bandF1 == null || f0 == null || f1 == null || f1 <= f0) {
            return;
        }
        /* Honest map only: place sample bins at their measured MHz. Never stretch
         * a narrow listen across a wider plot axis. */
        if (f1 < bandF0 || f0 > bandF1) {
            return;
        }
        const rowBins = placeBinsOnBand(bins, f0, f1, bandF0, bandF1, nBins);
        let any = false;
        for (let i = 0; i < length(rowBins); i++) {
            if (rowBins[i] > 0) {
                any = true;
                break;
            }
        }
        if (!any) {
            return;
        }
        if (fStart == null) {
            fStart = bandF0;
            fStop = bandF1;
        }
        let t = tVal;
        if (t == null) {
            t = nowFrac() - startedFrac;
        }
        if (t < 0) {
            t = 0;
        }
        push(sweeps, rowBins);
        push(times, t);
    }

    function ingestFftBuffer(durationHint, maxSamples)
    {
        const buf = readFftBuffer(FFT_OUT);
        if (!buf) {
            return 0;
        }
        const lim = maxSamples != null && maxSamples > 0 ? maxSamples : 16;
        const rows = samplesToRows(parseFftTlvs(buf, lim));
        if (!length(rows)) {
            return 0;
        }
        const tWall = nowFrac() - startedFrac;
        let localTsf0 = null;
        for (let i = 0; i < length(rows); i++) {
            if (length(sweeps) >= MAX_SWEEPS) {
                break;
            }
            let t = tWall + i * 0.0005;
            if (rows[i].tsf != null) {
                if (localTsf0 == null) {
                    localTsf0 = rows[i].tsf;
                }
                const d = (rows[i].tsf - localTsf0) / 1000000.0;
                if (d > 0) {
                    t = tWall + d;
                }
            }
            pushRow(rows[i].bins, rows[i].f_start, rows[i].f_stop, t);
        }
        return length(rows);
    }

    /* kn6plv-style ath9k full-band: repeat chanscan+iw scan for the section duration. */
    function runAth9kChanscanLoop()
    {
        const freqs = buildChanscanFreqList(plan);
        if (!length(freqs)) {
            return false;
        }
        mode = "fft";
        const kind = plan.mode === "all" ? "Full-band" : "Wide-plot";
        scanNote = `${kind} ath9k classic chanscan+iw scan (${length(freqs)} freqs); temporary mesh RF interrupt`;
        sectionIndex = 1;
        publishSession({ section_ends_at: nowSec() + sectionDur });
        let rounds = 0;
        let got = 0;
        while (nowFrac() < startedFrac + sectionDur) {
            if (fs.access(SESSION_STOP)) {
                break;
            }
            if (length(sweeps) >= MAX_SWEEPS) {
                break;
            }
            const pulse = captureAth9kChanscan(cap.iface, cap.phy, freqs);
            rounds++;
            if (pulse.ok) {
                got += ingestFftBuffer(sectionDur, 96);
            }
            if (fs.access(SESSION_STOP)) {
                break;
            }
        }
        sectionIndex = 1;
        publishSession({ section_ends_at: null });
        if (got > 0) {
            scanNote = `${kind} ath9k chanscan: ${got} FFT rows over ${rounds} scan rounds (${length(freqs)} freqs)`;
            return true;
        }
        scanNote = `${kind} ath9k chanscan empty after ${rounds} rounds; falling back to section retune`;
        return false;
    }

    function restoreRadio()
    {
        if (!retuned || !plan.ok) {
            return;
        }
        const r = restoreVerified(
            plan.iface,
            plan.ssid,
            plan.restore_channel,
            plan.restore_freq,
            plan.restore_bandwidth
        );
        if (!r.ok) {
            scanNote = (scanNote ? scanNote + "; " : "") +
                "WARNING: restore not verified — check radio channel / reboot if needed";
        }
        retuned = false;
    }

    function listenFftOnBand(untilFrac)
    {
        let useFft = !!cap.fft_available && !spectralCooldownActive();
        let emptyStreak = 0;
        let got = 0;
        while (nowFrac() < untilFrac && nowFrac() < endsFrac) {
            if (fs.access(SESSION_STOP)) {
                break;
            }
            if (length(sweeps) >= MAX_SWEEPS) {
                break;
            }
            if (!useFft) {
                break;
            }
            const pulse = runAth10kFftPulse(cap.iface, cap.phy, false, null);
            if (pulse.recovered) {
                recovered = true;
                useFft = false;
                usedSurveyFallback = true;
                break;
            }
            if (pulse.ok) {
                const buf = readFftBuffer(FFT_OUT);
                if (buf) {
                    const rows = samplesToRows(parseFftTlvs(buf, 8));
                    if (length(rows)) {
                        emptyStreak = 0;
                        for (let i = 0; i < length(rows); i++) {
                            pushRow(rows[i].bins, rows[i].f_start, rows[i].f_stop, null);
                            got++;
                        }
                    }
                    else {
                        emptyStreak++;
                    }
                }
                else {
                    emptyStreak++;
                }
                if (emptyStreak >= 3) {
                    useFft = false;
                    break;
                }
            }
            else {
                emptyStreak++;
                if (emptyStreak >= 3) {
                    useFft = false;
                    break;
                }
            }
        }
        return got;
    }

    function runSurveyLoop(untilFrac)
    {
        const endAt = untilFrac != null ? untilFrac : endsFrac;
        let prevSurvey = null;
        while (nowFrac() < endAt) {
            if (fs.access(SESSION_STOP)) {
                break;
            }
            const act = surveyActivityToBins(cap.iface, prevSurvey, nBins, bandF0, bandF1, amplify);
            prevSurvey = act.prev;
            if (act.bins) {
                pushRow(act.bins, bandF0, bandF1, null);
                if (length(sweeps) >= MAX_SWEEPS) {
                    break;
                }
            }
            petHardwareWatchdog();
            system("sleep 1");
        }
    }

    /* Multi-section: verified retune → listen one section → next → restore.
     * Used for ALL and for stitch (plot wider than one scan BW). */
    function runSectionDwellLoop()
    {
        const list = length(sections) ? sections : planSections(plan);
        const n = length(list);
        let sectionOk = 0;
        let sectionFail = 0;
        mode = "fft";
        const kind = plan.mode === "all" ? "Full-band" : "Stitched";
        scanNote = `${kind}: ${n} sections @ ${scanBw} MHz scan BW, ${sectionDur}s each (no freq stretch), then restore`;

        for (let i = 0; i < n; i++) {
            if (fs.access(SESSION_STOP)) {
                break;
            }
            if (length(sweeps) >= MAX_SWEEPS) {
                break;
            }
            const sec = list[i];
            sectionIndex = i + 1;
            const r = retuneVerified(
                plan.iface, plan.ssid, sec.number, sec.frequency, scanBw, { reloadWait: 8 }
            );
            retuned = true;
            if (!r.ok) {
                sectionFail++;
                publishSession({ section_ends_at: null });
                if (sectionFail >= 2) {
                    scanNote = `${scanNote}; abort after ${sectionFail} unverified retunes`;
                    break;
                }
                continue;
            }
            sectionOk++;
            sectionFail = 0;
            const sectionEnds = nowSec() + sectionDur;
            publishSession({ section_ends_at: sectionEnds });
            listenFftOnBand(nowFrac() + sectionDur);
        }

        sectionIndex = sectionCount;
        publishSession({ section_ends_at: null });

        if (sectionOk === 0 && cap.survey_available) {
            usedSurveyFallback = true;
            mode = "survey";
            scanNote = "Section retune failed; fell back to survey (not live FFT; not full-band spectrum)";
            runSurveyLoop(nowFrac() + sectionDur);
        }
        else {
            scanNote = `${kind}: ${sectionOk}/${n} verified sections @ ${scanBw} MHz (${sectionDur}s each)`;
        }
    }

    if (!cap.ok || !cap.capture_safe || !mode) {
        error = cap.unsupported_message || cap.error || "No capture path";
    }
    else if (!plan.ok) {
        error = plan.error || "Invalid channel/bandwidth selection";
    }
    else if (useSurveyDefault || (fragile && !allowFft)) {
        /* QCA9887 default: survey-only — no spectral_scan_ctl, no wifi reload. */
        try {
            mode = "survey";
            scanNote = "ath10k survey mode (safe default on QCA988x; no spectral FFT)";
            sectionIndex = 1;
            publishSession({ section_ends_at: nowSec() + sectionDur });
            runSurveyLoop(nowFrac() + sectionDur);
            if (!length(sweeps)) {
                error = "No survey sweeps captured";
            }
        }
        catch (e) {
            error = `${e}`;
        }
    }
    else if (useFragileFft) {
        /* Opt-in FFT: current channel only, short, spaced pulses, disable-only recover. */
        try {
            if (plan.mode !== "current" && plan.mode !== "single") {
                mode = "survey";
                usedSurveyFallback = true;
                scanNote = "ALL/wide refused on QCA988x FFT opt-in; using survey instead";
                sectionIndex = 1;
                publishSession({ section_ends_at: nowSec() + sectionDur });
                runSurveyLoop(nowFrac() + sectionDur);
            }
            else {
                mode = "fft";
                scanNote = `Experimental ath10k FFT ≤${sectionDur}s (disable-only recover; no wifi reload)`;
                if (plan.mode === "single") {
                    const r = retuneVerified(
                        plan.iface, plan.ssid, plan.channel, plan.frequency, scanBw,
                        { reloadWait: 10 }
                    );
                    if (r.ok) {
                        retuned = true;
                    }
                    else {
                        error = r.error || "Could not verify retune";
                    }
                }
                sectionIndex = 1;
                publishSession({ section_ends_at: nowSec() + sectionDur });
                let emptyStreak = 0;
                while (!error && nowFrac() < startedFrac + sectionDur) {
                    if (fs.access(SESSION_STOP)) {
                        break;
                    }
                    petHardwareWatchdog();
                    const pulse = runAth10kFftPulse(cap.iface, cap.phy, false, null);
                    if (pulse.recovered) {
                        recovered = true;
                        usedSurveyFallback = true;
                        mode = "survey";
                        scanNote = "FFT timeout — disable-only recover; finishing with survey";
                        break;
                    }
                    if (pulse.ok) {
                        const n = ingestFftBuffer(sectionDur, 8);
                        emptyStreak = n > 0 ? 0 : emptyStreak + 1;
                    }
                    else {
                        emptyStreak++;
                    }
                    if (emptyStreak >= 3) {
                        usedSurveyFallback = true;
                        mode = "survey";
                        break;
                    }
                    system("sleep 1");
                }
                if (!length(sweeps) && cap.survey_available) {
                    usedSurveyFallback = true;
                    mode = "survey";
                    runSurveyLoop(nowFrac() + 3);
                }
                if (!length(sweeps) && !error) {
                    error = "No FFT or survey sweeps (opt-in FFT)";
                }
            }
        }
        catch (e) {
            error = `${e}`;
        }
        restoreRadio();
        disableAllSpectral();
    }
    else if (plan.mode === "all" || plan.mode === "stitch" || sectionCount > 1) {
        try {
            let usedClassic = false;
            if (cap.chipset === "ath9k" && cap.fft_available) {
                usedClassic = runAth9kChanscanLoop();
                usedAth9kChanscan = usedClassic;
            }
            if (!usedClassic) {
                if (preferAth9kChanscan) {
                    /* Chanscan empty — restore full multi-section time budget. */
                    const extra = estimateSessionSec(sectionCount, sectionDur);
                    ends = nowSec() + extra;
                    endsFrac = nowFrac() + extra;
                    publishSession({ section_ends_at: null });
                }
                if (cap.fft_available || cap.survey_available) {
                    runSectionDwellLoop();
                }
                else {
                    error = "Multi-section scan needs FFT or survey";
                }
            }
            if (!length(sweeps)) {
                error = error || "No section sweeps captured";
            }
        }
        catch (e) {
            error = `${e}`;
        }
        restoreRadio();
        disableAllSpectral();
    }
    else if (cap.chipset === "ath10k") {
        let useFft = !!cap.fft_available && !spectralCooldownActive();
        let emptyStreak = 0;
        try {
            if (plan.mode === "single") {
                const r = retuneVerified(
                    plan.iface, plan.ssid, plan.channel, plan.frequency, scanBw,
                    { reloadWait: 10 }
                );
                if (r.ok) {
                    retuned = true;
                    scanNote = `Temporarily retuned to ch ${plan.channel} (plot ${plan.plot_bandwidth} MHz, scan ${scanBw} MHz, ${r.method})`;
                }
                else {
                    error = r.error || "Could not verify retune to requested channel";
                    scanNote = "Retune failed; not capturing off-channel without verification";
                    useFft = false;
                }
            }

            sectionIndex = 1;
            const sectionEnds = nowSec() + sectionDur;
            publishSession({ section_ends_at: sectionEnds });

            while (useFft && nowFrac() < startedFrac + sectionDur) {
                if (fs.access(SESSION_STOP)) {
                    break;
                }
                if (length(sweeps) >= MAX_SWEEPS) {
                    break;
                }

                const pulse = runAth10kFftPulse(cap.iface, cap.phy, false, null);
                if (pulse.recovered) {
                    recovered = true;
                    useFft = false;
                    usedSurveyFallback = true;
                    mode = "survey";
                    break;
                }
                if (pulse.ok) {
                    const n = ingestFftBuffer(sectionDur);
                    emptyStreak = n > 0 ? 0 : emptyStreak + 1;
                }
                else {
                    emptyStreak++;
                    if (emptyStreak >= 4) {
                        useFft = false;
                        usedSurveyFallback = true;
                        mode = "survey";
                        break;
                    }
                }
            }

            if (!length(sweeps) && cap.survey_available && plan.mode === "current") {
                usedSurveyFallback = true;
                mode = "survey";
                runSurveyLoop(nowFrac() + sectionDur);
            }
            if (!length(sweeps) && !error) {
                error = recovered
                    ? "FFT timed out (Wi-Fi recovered); survey also empty"
                    : "No FFT or survey sweeps captured";
            }
        }
        catch (e) {
            error = `${e}`;
        }
        restoreRadio();
    }
    else if (mode === "survey") {
        try {
            runSurveyLoop(ends);
            if (!length(sweeps)) {
                error = "No survey sweeps captured";
            }
        }
        catch (e) {
            error = `${e}`;
        }
    }
    else {
        const ctl = cap.paths.ctl;
        const relay = cap.paths.relay;
        try {
            if (plan.mode === "single") {
                const r = retuneVerified(
                    plan.iface, plan.ssid, plan.channel, plan.frequency, scanBw,
                    { reloadWait: 10 }
                );
                if (r.ok) {
                    retuned = true;
                    scanNote = `Temporarily retuned to ch ${plan.channel} (plot ${plan.plot_bandwidth} MHz, scan ${scanBw} MHz, ${r.method})`;
                }
                else {
                    error = r.error || "Could not verify retune to requested channel";
                }
            }
            sectionIndex = 1;
            publishSession({ section_ends_at: nowSec() + sectionDur });
            while (!error && nowFrac() < startedFrac + sectionDur) {
                if (fs.access(SESSION_STOP)) {
                    break;
                }
                writeSpectralCount(cap.paths, SPECTRAL_COUNT_DEFAULT);
                if (!writeCtl(ctl, "background") && !writeCtl(ctl, "manual")) {
                    error = "Cannot enable spectral scan";
                    break;
                }
                if (!writeCtl(ctl, "trigger")) {
                    error = "Cannot trigger spectral scan";
                    break;
                }
                if (sleepSec > 0) {
                    system(`sleep ${sleepSec}`);
                }
                else {
                    system("sleep 0");
                }
                system(`dd if=${relay} of=${FFT_OUT} bs=4096 count=8 2>/dev/null`);
                ingestFftBuffer();
                if (length(sweeps) >= MAX_SWEEPS) {
                    break;
                }
                if (fs.access(SESSION_STOP)) {
                    break;
                }
            }
        }
        catch (e) {
            error = `${e}`;
        }
        restoreRadio();
    }

    disableAllSpectral();
    restoreRadio();
    endScanHold(error ? `error:${error}` : "ok");
    fs.unlink(SESSION_STOP);
    fs.unlink(SESSION_PID);

    const ended = nowSec();
    let tStop = length(times) ? times[length(times) - 1] : (ended - started);
    const listenTotal = usedAth9kChanscan ? sectionDur : (sectionCount * sectionDur);
    if (tStop < listenTotal) {
        tStop = listenTotal;
    }
    let note = "RF spectral session complete; radio restored to normal use.";
    if (scanNote) {
        note = `${scanNote}. ${note}`;
    }
    if (mode === "survey" && usedSurveyFallback) {
        note = recovered
            ? "ath10k FFT timed out; Wi-Fi recovered; finished with survey waterfall."
            : "ath10k FFT empty/cooldown; finished with survey waterfall.";
    }
    else if (mode === "survey" && plan.ok && plan.mode === "all") {
        note = scanNote
            ? `${scanNote}.`
            : "Full-band survey fallback complete.";
    }
    else if (mode === "survey") {
        note = amplify
            ? "Survey waterfall complete (nl80211 noise/busy, amplify on)."
            : "Survey waterfall complete (nl80211 noise/busy, amplify off).";
    }
    if (fStart == null && plan.ok) {
        fStart = plan.f_start;
        fStop = plan.f_stop;
    }
    const cache = {
        ok: length(sweeps) > 0,
        error: length(sweeps) > 0 ? null : (error || "No sweeps captured"),
        have_cache: length(sweeps) > 0,
        pending: false,
        slot: 0,
        version: packageVersion(),
        iface: cap.iface,
        meta: {
            board: cap.board,
            iface: cap.iface,
            phy: cap.phy,
            chipset: cap.chipset,
            band: cap.band,
            capture_mode: mode,
            amplify_survey: mode === "survey" ? amplify : false,
            survey_fallback: usedSurveyFallback,
            recovered: recovered,
            pending: false,
            y_axis: "time",
            f_start: fStart,
            f_stop: fStop,
            t_start: 0,
            t_stop: tStop,
            started_at: started,
            ended_at: ended,
            duration_sec: ended - started,
            requested_duration_sec: listenTotal,
            section_duration_sec: sectionDur,
            section_count: sectionCount,
            sweep_count: length(sweeps),
            sample_interval_sec: sleepSec,
            scan_channel: plan.ok ? plan.channel : null,
            scan_bandwidth: scanBw,
            plot_bandwidth: plan.ok ? plan.plot_bandwidth : null,
            scan_mode: plan.ok ? plan.mode : null,
            axis_channels: plan.ok ? axisChannelsForPlan(plan) : [],
            experimental: cap.chipset === "ath10k",
            note: note
        },
        sweeps: sweeps,
        times: times
    };
    writeCache(cache);
    writeSessionState({
        running: false,
        started_at: started,
        ends_at: ends,
        ended_at: ended,
        duration_sec: totalEst,
        section_duration_sec: sectionDur,
        section_count: sectionCount,
        section_index: sectionCount,
        iface: cap.iface,
        chipset: cap.chipset,
        capture_mode: mode,
        sweep_count: length(sweeps),
        version: packageVersion()
    });
    return cache;
};

/**
 * Start background session worker (returns immediately). Admin must gate callers.
 */
export function startSessionAsync(preferredIface, durationSec, channelSel, bandwidthSel, allowFft, amplifySurvey)
{
    if (sessionIsRunning()) {
        const sess = readSessionState();
        const now = nowSec();
        const left = sess.ends_at != null ? ((int(sess.ends_at) - now) > 0 ? (int(sess.ends_at) - now) : 0) : null;
        return {
            ok: false,
            error: `A waterfall scan is already in progress on ${sess.iface || "unknown"}` +
                (left != null ? ` (~${left}s left)` : ""),
            running: true,
            remaining_sec: left,
            session: sess
        };
    }
    const cap = probeCapability(preferredIface);
    if (!cap.supported || !cap.capture_safe || !cap.capture_mode) {
        return {
            ok: false,
            error: cap.unsupported_message || "Waterfall capture not available",
            capability: cap
        };
    }
    const plan = resolveScanPlan(preferredIface, channelSel, bandwidthSel);
    if (!plan.ok) {
        return { ok: false, error: plan.error || "Invalid channel/bandwidth" };
    }
    let sectionDur = clampDuration(durationSec);
    const sections = planSections(plan);
    const sectionCount = length(sections) > 0 ? length(sections) : 1;
    const scanBw = plan.scan_bandwidth != null ? plan.scan_bandwidth : 20;
    const fragile = !!cap.fragile_ath10k;
    const amplify = amplifySurvey == null ? true : !!amplifySurvey;
    const useSurvey = fragile && !allowFft;
    const useFragileFft = fragile && !!allowFft;
    if (useFragileFft && sectionDur > ATH10K_FFT_MAX_SEC) {
        sectionDur = ATH10K_FFT_MAX_SEC;
    }
    const useAth9kChanscan =
        !fragile &&
        cap.chipset === "ath9k" &&
        cap.fft_available &&
        (plan.mode === "all" || plan.mode === "stitch" || sectionCount > 1);
    const progressSections = (useSurvey || useFragileFft) ? 1 : (useAth9kChanscan ? 1 : sectionCount);
    const totalEst = (useSurvey || useFragileFft)
        ? (sectionDur + 3)
        : (useAth9kChanscan
            ? (sectionDur + SECTION_RESTORE_SEC)
            : estimateSessionSec(sectionCount, sectionDur));
    const ifaceArg = preferredIface ? ` -i ${preferredIface}` : "";
    let chArg = "";
    let bwArg = "";
    let fftArg = "";
    let ampArg = "";
    if (channelSel != null && `${channelSel}` !== "") {
        chArg = ` -c ${channelSel}`;
    }
    if (bandwidthSel != null && `${bandwidthSel}` !== "") {
        bwArg = ` -b ${bandwidthSel}`;
    }
    if (allowFft) {
        fftArg = " -f";
    }
    if (!amplify) {
        ampArg = " --no-amplify";
    }
    fs.unlink(SESSION_STOP);
    const started = nowSec();
    const startMode = useSurvey ? "survey" : (useFragileFft ? "fft" : cap.capture_mode);
    const rotated = rotateCacheForNewScan(cap.iface);
    writeSessionState({
        running: true,
        started_at: started,
        ends_at: started + totalEst,
        duration_sec: totalEst,
        section_duration_sec: sectionDur,
        section_count: progressSections,
        section_index: 0,
        section_ends_at: null,
        iface: cap.iface,
        chipset: cap.chipset,
        capture_mode: startMode,
        allow_fft: !!allowFft,
        amplify_survey: startMode === "survey" ? amplify : false,
        scan_channel: plan.channel,
        scan_bandwidth: scanBw,
        plot_bandwidth: plan.plot_bandwidth,
        scan_mode: plan.mode,
        version: packageVersion()
    });
    system(`waterfall-session${ifaceArg} -d ${sectionDur}${chArg}${bwArg}${fftArg}${ampArg} >/tmp/waterfall-session.log 2>&1 &`);
    let warn;
    if (useSurvey) {
        warn = `Survey waterfall on ${cap.iface} for ${sectionDur}s (QCA988x safe default — no spectral FFT)` +
            (amplify ? "; amplify on" : "; amplify off") + ".";
    }
    else if (useFragileFft) {
        warn = `Experimental FFT on ${cap.iface} ≤${sectionDur}s (disable-only recover). Prefer survey for daily use.`;
    }
    else if (useAth9kChanscan) {
        const freqs = buildChanscanFreqList(plan);
        warn = `ath9k classic chanscan+iw scan on ${cap.iface} (${length(freqs)} freqs, ${sectionDur}s). Temporary mesh RF interrupt — radio returns when scan ends.`;
    }
    else if (plan.mode === "all") {
        warn = `Full-band on ${cap.iface}: ${sectionCount} sections × ${sectionDur}s @ ${scanBw} MHz scan BW (~${totalEst}s incl. retune/restore).`;
    }
    else if (plan.mode === "stitch" || sectionCount > 1) {
        warn = `Stitched plot ${plan.plot_bandwidth} MHz on ${cap.iface}: ${sectionCount} sections × ${sectionDur}s @ ${scanBw} MHz listen (~${totalEst}s). No frequency stretch.`;
    }
    else if (plan.mode === "single") {
        warn = `Scan ch ${plan.channel} (plot ${plan.plot_bandwidth} MHz, scan ${scanBw} MHz) for ${sectionDur}s + restore.`;
    }
    else if (cap.chipset === "ath10k") {
        warn = `ath10k capture on ${cap.iface} (${sectionDur}s).`;
    }
    else {
        warn = `Spectral capture on ${cap.iface} for ${sectionDur}s.`;
    }
    return {
        ok: true,
        started: true,
        started_at: started,
        ends_at: started + totalEst,
        duration_sec: totalEst,
        section_duration_sec: sectionDur,
        section_count: progressSections,
        iface: cap.iface,
        chipset: cap.chipset,
        capture_mode: startMode,
        allow_fft: !!allowFft,
        amplify_survey: startMode === "survey" ? amplify : false,
        scan_channel: plan.channel,
        scan_bandwidth: scanBw,
        plot_bandwidth: plan.plot_bandwidth,
        scan_mode: plan.mode,
        f_start: plan.f_start,
        f_stop: plan.f_stop,
        cache_slots: rotated?.slots || listCacheSlots(cap.iface),
        warning: warn
    };
};

export function stopSession()
{
    fs.writefile(SESSION_STOP, "1\n");
    system("sleep 1");
    disableAllSpectral();
    endScanHold("stop");
    const st = readSessionState();
    st.running = false;
    st.stopped_at = nowSec();
    writeSessionState(st);
    return { ok: true, stopped: true, session: st, cache: readCache(st.iface) };
};

export function sessionStatus(preferredIface)
{
    const rlist = listRadios();
    const cap = probeCapability(preferredIface);
    const running = sessionIsRunning();
    const sess = readSessionState();
    const now = nowSec();
    let remaining = null;
    if (running && sess.ends_at != null) {
        remaining = int(sess.ends_at) - now;
        if (remaining < 0) {
            remaining = 0;
        }
    }
    let sectionRemaining = null;
    if (running && sess.section_ends_at != null) {
        sectionRemaining = int(sess.section_ends_at) - now;
        if (sectionRemaining < 0) {
            sectionRemaining = 0;
        }
        sess.section_remaining_sec = sectionRemaining;
    }
    sess.server_now = now;
    if (remaining != null) {
        sess.remaining_sec = remaining;
    }
    const sel = preferredIface || cap.iface || null;
    const cache = readCache(sel);
    const scan = getScanOptions(sel);
    const usage = cacheDiskUsage();
    return {
        ok: true,
        version: packageVersion(),
        running: running,
        remaining_sec: remaining,
        section_remaining_sec: sectionRemaining,
        section_count: sess.section_count != null ? sess.section_count : null,
        section_index: sess.section_index != null ? sess.section_index : null,
        section_duration_sec: sess.section_duration_sec != null ? sess.section_duration_sec : null,
        scan_mode: sess.scan_mode != null ? sess.scan_mode : null,
        server_now: now,
        session: sess,
        have_cache: cache.have_cache,
        sweep_count: length(cache.sweeps || []),
        cache_bytes: usage.bytes,
        cache_files: usage.files,
        cache_slots: listCacheSlots(sel),
        durations: allowedDurations(),
        default_duration: SESSION_DEFAULT_SEC,
        max_duration: SESSION_MAX_SEC,
        radios: rlist,
        selected_iface: sel,
        prefer_survey: cap.prefer_survey,
        fft_opt_in: cap.fft_opt_in,
        fragile_ath10k: cap.fragile_ath10k,
        max_fft_sec: cap.max_fft_sec,
        scan: scan,
        capability: {
            supported: cap.supported,
            unsupported_message: cap.unsupported_message,
            iface: cap.iface,
            phy: cap.phy,
            chipset: cap.chipset,
            band: cap.band,
            channel: cap.channel,
            bandwidth: cap.bandwidth,
            frequency_mhz: cap.frequency_mhz,
            fft_available: cap.fft_available,
            survey_available: cap.survey_available,
            capture_mode: cap.capture_mode,
            prefer_survey: cap.prefer_survey,
            fft_opt_in: cap.fft_opt_in,
            fragile_ath10k: cap.fragile_ath10k,
            max_fft_sec: cap.max_fft_sec,
            capture_safe: cap.capture_safe,
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
    push(lines, `fft_available ${cap.fft_available}  survey_available ${cap.survey_available}  capture_mode ${cap.capture_mode || "none"}  capture_safe ${cap.capture_safe}  ctl ${cap.spectral_ctl}  relay ${cap.spectral_relay}`);
    if (cap.prefer_survey) {
        push(lines, `prefer_survey true  fft_opt_in ${!!cap.fft_opt_in}  max_fft_sec ${cap.max_fft_sec || 5}`);
    }
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
    push(lines, "RF note: ath9k FFT disrupts RF; QCA988x ath10k defaults to survey (FFT opt-in, disable-only recover).");
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
        push(lines, "NOTE: capture marked experimental.");
    }
    push(lines, `fft_file ${result.fft_file}  bytes ${result.fft_bytes}`);
    if (result.sweep) {
        push(lines, `parsed bins ${length(result.sweep.bins)}  f ${result.sweep.f_start}-${result.sweep.f_stop} MHz  noise ${result.sweep.noise}`);
    }
    push(lines, "Spectral disabled after capture (RF restored).");
    return join("\n", lines) + "\n";
};
