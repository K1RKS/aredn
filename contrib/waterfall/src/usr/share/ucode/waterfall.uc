/**
 * Waterfall package library.
 * RF spectrum probe/capture for 5 GHz AREDN radios.
 * Focus: Rocket M5, PowerBeam 500 / 500 AC, MikroTik hAP ac lite.
 *
 * Capture modes:
 *   ath9k  — spectral FFT via spectral_scan_ctl
 *   ath10k — spectral FFT via isolated worker (flock + hard timeout + local
 *            Wi-Fi recovery). Survey waterfall is the automatic fallback if
 *            FFT returns empty, is in cooldown, or recovery fires.
 *
 * ath10k spectral_scan_ctl can wedge QCA988x on IBSS/mesh; the worker never
 * leaves ctl enabled, serializes captures, and recovers with iface bounce /
 * wifi reload (not power cycle) when the hard timeout fires.
 */

import * as fs from "fs";
import * as nl80211 from "nl80211";
import * as radios from "aredn.radios";
import * as hardware from "aredn.hardware";

const FFT_OUT = "/tmp/waterfall-fft.bin";
const CACHE_JSON = "/tmp/waterfall-cache.json";
const CACHE_PREFIX = "/tmp/waterfall-cache-";
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
const SPECTRAL_COOLDOWN = "/tmp/waterfall-spectral.cooldown";

export function packageVersion()
{
    return "0.2.21-r0";
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

export function captureModeForChipset(chipset)
{
    if (chipset === "ath9k" || chipset === "ath10k") {
        return "fft";
    }
    return null;
};

function ath10kNote(board)
{
    const bid = lc(board || "");
    if (match(bid, /952ui-5ac2nd|hap ac lite/)) {
        return "hAP ac lite 5 GHz (ath10k QCA9887): isolated FFT worker (timeout+recovery); survey fallback if FFT empty/cooldown.";
    }
    return "ath10k: isolated FFT worker (timeout+local Wi-Fi recovery); survey fallback if FFT empty/cooldown.";
}

function focusNote(chipset, fftAvailable, board, captureSafe, mode)
{
    if (chipset === "ath9k" && fftAvailable) {
        return "ath9k spectral FFT available (Rocket M5 / PowerBeam M5 class; also hAP ac lite 2.4 GHz). Current-channel capture supported.";
    }
    if (chipset === "ath10k") {
        return ath10kNote(board);
    }
    if (chipset === "unknown") {
        return "Chipset not recognized for spectral capture.";
    }
    return `Chipset ${chipset} has no waterfall path in this package yet.`;
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
    const until = int(trim(fs.readfile(SPECTRAL_COOLDOWN) || "0"));
    return until > nowSec();
}

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
    const rc = system(`/usr/bin/waterfall-ath10k-fft -i ${iface} -p ${phy} -o ${FFT_OUT} -t ${hard}${durArg}${scan} >/tmp/waterfall-ath10k-fft.log 2>&1`);
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
            const binCount = plen - hdr;
            if (noise < -140 || noise > -20 || freq1 < 4900 || freq1 > 6100 ||
                (binCount !== 64 && binCount !== 128 && binCount !== 256)) {
                pos++;
                continue;
            }
            const tsf = be64(buf, base + 13);
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
                tsf: tsf,
                bins: downsampleBins(bins, TARGET_BINS)
            });
            pos += total;
        }
        else if (typ === ATH_FFT_SAMPLE_HT20) {
            /* tlv + max_exp(1) + freq(2) + rssi(1) + noise(1) + max_mag(2) + max_index(1) + bitmap(1) + tsf(8) + data(56) = 3+73 */
            if (total < 3 + 17 + 56 || plen !== 73) {
                pos++;
                continue;
            }
            const freq = be16(buf, base + 1);
            if (freq < 2300 || freq > 6100) {
                pos++;
                continue;
            }
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
            pos += total;
        }
        else if (typ === ATH_FFT_SAMPLE_HT20_40) {
            if (total < 3 + 17 + 128) {
                pos++;
                continue;
            }
            const freq = be16(buf, base + 1);
            if (freq < 2300 || freq > 6100) {
                pos++;
                continue;
            }
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
        const mode = captureModeForChipset(chipset);
        const fftAvailable = pathsOk && (chipset === "ath9k" || chipset === "ath10k");
        const surveyAvailable = chipset === "ath10k";
        const selectable = fftAvailable || surveyAvailable;
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
            capture_mode: fftAvailable ? "fft" : (surveyAvailable ? "survey" : null),
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
    const mode = captureModeForChipset(chipset);
    const fftAvailable = pathsOk && (chipset === "ath9k" || chipset === "ath10k");
    const surveyAvailable = chipset === "ath10k";
    const captureSafe = fftAvailable || surveyAvailable;
    const captureMode = fftAvailable ? "fft" : (surveyAvailable ? "survey" : null);

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

/**
 * Resolve GUI channel/bw ("all" or numbers) into a capture plan.
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

    let bw = curBw;
    if (!wantAllBw && bandwidthSel != null && bandwidthSel !== "" && bandwidthSel !== "current") {
        bw = int(bandwidthSel);
    }
    if (bw == null || bw <= 0) {
        bw = 10;
    }

    if (wantAllCh) {
        /* Full-band axis from densest list; hop using 20 MHz centers when available. */
        const dense = channelListForBw(radio, length(channelListForBw(radio, 5)) ? 5 : 10);
        const hopBw = length(channelListForBw(radio, 20)) ? 20 : bw;
        const hop = channelListForBw(radio, hopBw);
        if (!length(dense) && !length(hop)) {
            return { ok: false, error: "No channels available for ALL scan" };
        }
        const use = length(dense) ? dense : hop;
        const first = use[0];
        const last = use[length(use) - 1];
        const half = (hopBw / 2.0);
        return {
            ok: true,
            mode: "all",
            iface: iface,
            ssid: opts.current_ssid,
            restore_channel: curCh,
            restore_bandwidth: curBw,
            restore_freq: hardware.getChannelFrequency(iface, curCh),
            bandwidth: hopBw,
            channel: "all",
            hop_channels: hop,
            f_start: first.frequency - half,
            f_stop: last.frequency + half
        };
    }

    let ch = curCh;
    if (channelSel != null && channelSel !== "" && channelSel !== "current") {
        ch = int(channelSel);
    }
    const span = freqSpanForChannel(iface, ch, bw);
    if (!span) {
        return { ok: false, error: `Cannot resolve frequency for channel ${ch}` };
    }
    const same = (ch === curCh && bw === curBw);
    return {
        ok: true,
        mode: same ? "current" : "single",
        iface: iface,
        ssid: opts.current_ssid,
        restore_channel: curCh,
        restore_bandwidth: curBw,
        restore_freq: hardware.getChannelFrequency(iface, curCh),
        channel: ch,
        bandwidth: bw,
        hop_channels: [{ number: ch, frequency: span.frequency }],
        f_start: span.f_start,
        f_stop: span.f_stop,
        frequency: span.frequency
    };
};

/* IBSS leave/join hop is unsafe on AREDN mesh (leaves iface unchannelized).
 * Single-channel retune uses UCI + wifi reload; ALL uses survey (no retune). */
function retuneViaWifi(iface, channel, bandwidth, waitSec)
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
    const w = waitSec != null ? waitSec : 8;
    system(`sleep ${w}`);
    return true;
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
    const n = length(bins);
    const span = sampleF1 - sampleF0;
    for (let i = 0; i < n; i++) {
        const fc = sampleF0 + (i + 0.5) * (span / n);
        let idx = int(((fc - bandF0) / (bandF1 - bandF0)) * nOut);
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

/**
 * Build one heatmap sweep from nl80211 survey dump (ath10k-safe path).
 * Bin intensity = noise above a floor, blended with channel busy fraction when present.
 */
export function surveyToSweep(iface, nBins)
{
    const rows = getSurveySummary(iface);
    const usable = [];
    for (let i = 0; i < length(rows); i++) {
        const r = rows[i];
        if (r.frequency == null || r.noise == null) {
            continue;
        }
        /* Prefer 5 GHz survey rows when present; keep all if none qualify. */
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
    const bins = [];
    for (let i = 0; i < nb; i++) {
        push(bins, 0);
    }
    for (let i = 0; i < length(use); i++) {
        const r = use[i];
        let idx = int(((r.frequency - fMin) / (fMax - fMin)) * (nb - 1));
        if (idx < 0) {
            idx = 0;
        }
        if (idx >= nb) {
            idx = nb - 1;
        }
        let v = 0;
        /* Map noise floor (-120..-60) into 0..100 */
        const n = r.noise;
        if (n != null) {
            v = int((n + 120) * 100 / 60);
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
        if (v > bins[idx]) {
            bins[idx] = v;
        }
        /* Soft fill neighbors so sparse channel lists still look continuous */
        if (idx > 0 && bins[idx - 1] < int(v * 0.6)) {
            bins[idx - 1] = int(v * 0.6);
        }
        if (idx + 1 < nb && bins[idx + 1] < int(v * 0.6)) {
            bins[idx + 1] = int(v * 0.6);
        }
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
        sweeps: [],
        times: [],
        meta: iface ? { iface: iface } : null,
        iface: iface || null
    };
}

function cachePathForIface(iface)
{
    if (!iface || !match(iface, /^[a-zA-Z0-9]+$/)) {
        return CACHE_JSON;
    }
    return `${CACHE_PREFIX}${iface}.json`;
}

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

export function readCache(iface)
{
    let path = cachePathForIface(iface);
    if (!fs.access(path) && iface && fs.access(CACHE_JSON)) {
        /* migrate legacy single-cache if it matches this iface */
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
        return emptyCache(iface);
    }
    try {
        const c = json(fs.readfile(path));
        c.ok = true;
        c.have_cache = length(c.sweeps || []) > 0;
        c.version = packageVersion();
        c.iface = c.meta?.iface || iface || null;
        return c;
    }
    catch (_) {
        return {
            ok: false,
            error: "Corrupt waterfall cache",
            have_cache: false,
            sweeps: [],
            version: packageVersion(),
            iface: iface || null
        };
    }
};

export function writeCache(cache)
{
    const iface = cache?.meta?.iface || cache?.iface || null;
    const path = cachePathForIface(iface);
    fs.writefile(path, sprintf("%J", cache));
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
 * One-shot capture. ath9k: inline FFT. ath10k: isolated FFT worker, survey fallback.
 */
export function captureSpectral(preferredIface)
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
        let modeUsed = "fft";
        let sweep = null;
        let error = null;
        let bytes = 0;
        let recovered = false;

        if (cap.fft_available && !spectralCooldownActive()) {
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
        else if (spectralCooldownActive()) {
            error = "spectral cooldown active after prior failure";
        }

        if (!sweep && cap.survey_available) {
            modeUsed = "survey";
            sweep = surveyToSweep(cap.iface);
            if (sweep) {
                error = recovered
                    ? "FFT timed out (Wi-Fi recovered); using survey fallback"
                    : (error ? `${error}; using survey fallback` : null);
            }
            else if (!error) {
                error = "No survey samples (empty nl80211 survey dump)";
            }
        }

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
 * Bounded RF session: dense time rows (Y = time from 0 → duration).
 * ALL = survey on full-band axis (no hop). Single non-current = temporary UCI retune.
 */
export function runSession(preferredIface, durationSec, channelSel, bandwidthSel)
{
    durationSec = clampDuration(durationSec);
    const sleepSec = durationSec >= 300 ? 1 : 0;
    fs.unlink(SESSION_STOP);

    const cap = probeCapability(preferredIface);
    const plan = resolveScanPlan(preferredIface, channelSel, bandwidthSel);
    const started = nowSec();
    const startedFrac = nowFrac();
    const ends = started + durationSec;
    const endsFrac = startedFrac + durationSec;
    const sweeps = [];
    const times = [];
    let mode = cap.capture_mode;
    let usedSurveyFallback = false;
    let recovered = false;
    let retuned = false;
    let scanNote = null;

    writeSessionState({
        running: true,
        started_at: started,
        ends_at: ends,
        duration_sec: durationSec,
        iface: cap.iface,
        chipset: cap.chipset,
        capture_mode: mode,
        scan_channel: plan.ok ? plan.channel : null,
        scan_bandwidth: plan.ok ? plan.bandwidth : null,
        version: packageVersion()
    });

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
        let rowBins = bins;
        if (bandF0 != null && bandF1 != null && f0 != null && f1 != null &&
            (f0 !== bandF0 || f1 !== bandF1 || length(bins) !== nBins)) {
            rowBins = placeBinsOnBand(bins, f0, f1, bandF0, bandF1, nBins);
        }
        else if (length(bins) !== nBins) {
            rowBins = placeBinsOnBand(bins, f0 != null ? f0 : bandF0, f1 != null ? f1 : bandF1,
                bandF0 != null ? bandF0 : f0, bandF1 != null ? bandF1 : f1, nBins);
        }
        if (fStart == null) {
            fStart = f0;
            fStop = f1;
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

    function ingestFftBuffer(durationHint)
    {
        const buf = readFftBuffer(FFT_OUT);
        if (!buf) {
            return 0;
        }
        const rows = samplesToRows(parseFftTlvs(buf, 16));
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

    function restoreRadio()
    {
        if (!retuned || !plan.ok) {
            return;
        }
        if (plan.restore_channel != null) {
            retuneViaWifi(plan.iface, plan.restore_channel, plan.restore_bandwidth, 10);
        }
        retuned = false;
    }

    function runSurveyLoop(untilFrac)
    {
        const endAt = untilFrac != null ? untilFrac : endsFrac;
        while (nowFrac() < endAt) {
            if (fs.access(SESSION_STOP)) {
                break;
            }
            const sweep = surveyToSweep(cap.iface, nBins);
            if (sweep) {
                pushRow(sweep.bins, sweep.f_start, sweep.f_stop, null);
                if (length(sweeps) >= MAX_SWEEPS) {
                    break;
                }
            }
            system("sleep 1");
        }
    }

    if (!cap.ok || !cap.capture_safe || !mode) {
        error = cap.unsupported_message || cap.error || "No capture path";
    }
    else if (!plan.ok) {
        error = plan.error || "Invalid channel/bandwidth selection";
    }
    else if (plan.mode === "all" && cap.survey_available) {
        /* Full-band: survey only — never hop/retune (breaks mesh IBSS). */
        mode = "survey";
        scanNote = "Full-band survey (no RF retune; channel hop disabled for mesh safety)";
        try {
            runSurveyLoop(endsFrac);
            if (!length(sweeps)) {
                error = "No survey sweeps captured";
            }
        }
        catch (e) {
            error = `${e}`;
        }
    }
    else if (cap.chipset === "ath10k") {
        let useFft = !!cap.fft_available && !spectralCooldownActive();
        let emptyStreak = 0;
        try {
            if (plan.mode === "single") {
                if (retuneViaWifi(plan.iface, plan.channel, plan.bandwidth, 10)) {
                    retuned = true;
                    scanNote = `Temporarily retuned to ch ${plan.channel} @ ${plan.bandwidth} MHz for scan`;
                }
                else {
                    scanNote = "Retune failed; capturing on current radio channel";
                }
            }
            else if (plan.mode === "all") {
                scanNote = "ALL without survey path; capturing current RF on full-band axis (no hop)";
            }

            while (nowFrac() < endsFrac) {
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
                    mode = "survey";
                    break;
                }
                if (pulse.ok) {
                    const n = ingestFftBuffer(durationSec);
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

            if (!length(sweeps) && cap.survey_available) {
                usedSurveyFallback = true;
                mode = "survey";
                runSurveyLoop(nowFrac() + durationSec);
            }
            if (!length(sweeps)) {
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
                if (retuneViaWifi(plan.iface, plan.channel, plan.bandwidth, 10)) {
                    retuned = true;
                    scanNote = `Temporarily retuned to ch ${plan.channel} @ ${plan.bandwidth} MHz for scan`;
                }
            }
            else if (plan.mode === "all") {
                scanNote = "ALL without hop (mesh-safe); capturing current RF on full-band axis";
            }
            while (nowFrac() < endsFrac) {
                if (fs.access(SESSION_STOP)) {
                    break;
                }
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
    fs.unlink(SESSION_STOP);
    fs.unlink(SESSION_PID);

    const ended = nowSec();
    let tStop = length(times) ? times[length(times) - 1] : (ended - started);
    if (tStop < durationSec) {
        tStop = durationSec;
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
            ? `${scanNote}. Radio left on configured channel.`
            : "Full-band survey waterfall complete (nl80211 noise/busy).";
    }
    else if (mode === "survey") {
        note = "Survey waterfall complete (nl80211 noise/busy).";
    }
    if (fStart == null && plan.ok) {
        fStart = plan.f_start;
        fStop = plan.f_stop;
    }
    const cache = {
        ok: length(sweeps) > 0,
        error: length(sweeps) > 0 ? null : (error || "No sweeps captured"),
        have_cache: length(sweeps) > 0,
        version: packageVersion(),
        iface: cap.iface,
        meta: {
            board: cap.board,
            iface: cap.iface,
            phy: cap.phy,
            chipset: cap.chipset,
            band: cap.band,
            capture_mode: mode,
            survey_fallback: usedSurveyFallback,
            recovered: recovered,
            y_axis: "time",
            f_start: fStart,
            f_stop: fStop,
            t_start: 0,
            t_stop: tStop,
            started_at: started,
            ended_at: ended,
            duration_sec: ended - started,
            requested_duration_sec: durationSec,
            sweep_count: length(sweeps),
            sample_interval_sec: sleepSec,
            scan_channel: plan.ok ? plan.channel : null,
            scan_bandwidth: plan.ok ? plan.bandwidth : null,
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
        duration_sec: durationSec,
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
export function startSessionAsync(preferredIface, durationSec, channelSel, bandwidthSel)
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
    durationSec = clampDuration(durationSec);
    const ifaceArg = preferredIface ? ` -i ${preferredIface}` : "";
    let chArg = "";
    let bwArg = "";
    if (channelSel != null && `${channelSel}` !== "") {
        chArg = ` -c ${channelSel}`;
    }
    if (bandwidthSel != null && `${bandwidthSel}` !== "") {
        bwArg = ` -b ${bandwidthSel}`;
    }
    fs.unlink(SESSION_STOP);
    const started = nowSec();
    writeSessionState({
        running: true,
        started_at: started,
        ends_at: started + durationSec,
        duration_sec: durationSec,
        iface: cap.iface,
        chipset: cap.chipset,
        capture_mode: cap.capture_mode,
        scan_channel: plan.channel,
        scan_bandwidth: plan.bandwidth,
        version: packageVersion()
    });
    system(`waterfall-session${ifaceArg} -d ${durationSec}${chArg}${bwArg} >/tmp/waterfall-session.log 2>&1 &`);
    const warn = plan.mode === "all"
        ? `Full-band survey on ${cap.iface} (no channel hop). Up to ${durationSec}s.`
        : (plan.mode === "single"
            ? `Temporarily retune to ch ${plan.channel} @ ${plan.bandwidth} MHz on ${cap.iface} (RF disrupted up to ${durationSec}s + reload).`
            : (cap.chipset === "ath10k"
                ? `ath10k isolated FFT on ${cap.iface} (hard timeout ${ATH10K_FFT_HARD_TIMEOUT}s + recovery; survey fallback). Up to ${durationSec}s.`
                : `Spectral capture disrupts RF for up to ${durationSec}s on ${cap.iface}.`));
    return {
        ok: true,
        started: true,
        started_at: started,
        ends_at: started + durationSec,
        duration_sec: durationSec,
        iface: cap.iface,
        chipset: cap.chipset,
        capture_mode: cap.capture_mode,
        scan_channel: plan.channel,
        scan_bandwidth: plan.bandwidth,
        scan_mode: plan.mode,
        f_start: plan.f_start,
        f_stop: plan.f_stop,
        warning: warn
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
    const sel = preferredIface || cap.iface || null;
    const cache = readCache(sel);
    const scan = getScanOptions(sel);
    return {
        ok: true,
        version: packageVersion(),
        running: running,
        remaining_sec: remaining,
        server_now: now,
        session: sess,
        have_cache: cache.have_cache,
        sweep_count: length(cache.sweeps || []),
        durations: allowedDurations(),
        default_duration: SESSION_DEFAULT_SEC,
        max_duration: SESSION_MAX_SEC,
        radios: rlist,
        selected_iface: sel,
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
    push(lines, "RF note: ath9k FFT disrupts RF; ath10k uses isolated FFT worker (timeout+recovery) with survey fallback.");
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
