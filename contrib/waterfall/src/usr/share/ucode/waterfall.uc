/**
 * Waterfall package library.
 * RF spectrum probe/capture for 5 GHz AREDN radios (ath9k first; ath10k experimental).
 * Focus: Rocket M5, PowerBeam 500 / 500 AC, MikroTik hAP ac lite (5 GHz).
 */

import * as fs from "fs";
import * as nl80211 from "nl80211";
import * as radios from "aredn.radios";
import * as hardware from "aredn.hardware";

const FFT_OUT = "/tmp/waterfall-fft.bin";
const DBG_BASE = "/sys/kernel/debug/ieee80211";

export function packageVersion()
{
    return "0.1.4-r0";
}

function isMeshMode(mode)
{
    return mode === radios.RADIO_MESH || mode === radios.RADIO_MESHSTA ||
        mode === radios.RADIO_MESHPTP || mode === radios.RADIO_MESHPTMP;
}

/**
 * True when the iface's channel plan / current channel is 5 GHz.
 */
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
}

/**
 * Prefer mesh radios on 5 GHz (hAP ac lite wlan1 / QCA9887, Ubiquiti 5 GHz).
 * Fall back to any mesh radio, then first configured radio.
 */
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
}

/**
 * Summarize all radios (useful on dual-band hAP ac lite).
 */
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
        out.push({
            iface: r.iface,
            phy: phy,
            chipset: chipset,
            mode: r.mode?.mode || "unknown",
            channel: channel,
            band: five ? "5GHz" : "other",
            fft_paths: !!spectralPaths(phy, chipset)
        });
    }
    return out;
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

/**
 * Primary target boards (name/id substrings, lowercased).
 */
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

/**
 * Whether Waterfall can run on this node, plus a user-facing reason if not.
 */
export function supportStatus(cap)
{
    const board = cap?.board || "";
    const radios = cap?.radios || listRadios();
    let anyFft = !!(cap?.fft_available);
    if (!anyFft) {
        for (let i = 0; i < length(radios); i++) {
            if (radioHasFft(radios[i])) {
                anyFft = true;
                break;
            }
        }
    }

    if (anyFft) {
        return {
            supported: true,
            message: null
        };
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
}

/**
 * Capability probe for one wifi iface (or auto-selected 5 GHz mesh radio).
 */
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
}

/**
 * NL80211 survey summary (noise / busy) — works without FFT.
 */
export function getSurveySummary(iface)
{
    const survey = nl80211.request(nl80211.const.NL80211_CMD_GET_SURVEY, nl80211.const.NLM_F_DUMP, { dev: iface }) || [];
    const out = [];
    for (let i = 0; i < length(survey); i++) {
        if (survey[i].dev !== iface) {
            continue;
        }
        const si = survey[i].survey_info || {};
        out.push({
            frequency: survey[i].frequency || si.frequency || null,
            noise: si.noise ?? null,
            time: si.time ?? null,
            time_busy: si.time_busy ?? null,
            time_rx: si.time_rx ?? null,
            time_tx: si.time_tx ?? null
        });
    }
    return out;
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

/**
 * Capture spectral FFT samples into /tmp/waterfall-fft.bin (current channel).
 * Prefer ath9k; ath10k attempted but marked experimental (hAP ac lite 5 GHz, PBE-5AC).
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

    system(`dd if=${relay} of=/dev/null bs=4096 count=64 2>/dev/null`);
    if (!writeCtl(ctl, "background")) {
        return { ok: false, error: `Cannot write ${ctl}`, capability: cap };
    }
    if (!writeCtl(ctl, "trigger")) {
        writeCtl(ctl, "disable");
        return { ok: false, error: "Cannot trigger spectral scan", capability: cap };
    }
    system("sleep 1");
    system(`dd if=${relay} of=${FFT_OUT} bs=4096 count=256 2>/dev/null`);
    writeCtl(ctl, "disable");

    const st = fs.stat(FFT_OUT);
    const bytes = st ? int(st.size) : 0;
    const survey = getSurveySummary(cap.iface);

    return {
        ok: bytes > 0,
        error: bytes > 0 ? null : "No FFT samples captured (empty relay). Radio may be idle or spectral unsupported in this mode.",
        capability: cap,
        fft_file: FFT_OUT,
        fft_bytes: bytes,
        survey: survey,
        experimental: cap.chipset === "ath10k"
    };
}

export function formatProbeReport(cap)
{
    const lines = [];
    lines.push(`waterfall ${cap.version || packageVersion()}`);
    if (cap.board) {
        lines.push(`board ${cap.board}`);
    }
    if (cap.supported === false) {
        lines.push("NOT SUPPORTED");
        if (cap.unsupported_message) {
            lines.push(cap.unsupported_message);
        }
    }
    if (!cap.ok) {
        if (cap.supported !== false) {
            lines.push(`ERROR: ${cap.error}`);
        }
        return join(lines, "\n") + "\n";
    }
    lines.push(`selected ${cap.iface}  phy ${cap.phy}  chipset ${cap.chipset}  band ${cap.band}`);
    lines.push(`mode ${cap.mode}  channel ${cap.channel}  freq ${cap.frequency_mhz} MHz`);
    lines.push(`fft_available ${cap.fft_available}  ctl ${cap.spectral_ctl}  relay ${cap.spectral_relay}`);
    if (cap.supported !== false) {
        lines.push(cap.note);
    }
    if (cap.radios && length(cap.radios) > 1) {
        lines.push("radios:");
        for (let i = 0; i < length(cap.radios); i++) {
            const r = cap.radios[i];
            lines.push(`  ${r.iface} ${r.phy} ${r.chipset} ${r.band} mode=${r.mode} ch=${r.channel}`);
        }
        lines.push("(auto-select prefers 5 GHz mesh; pass -i / iface= to override)");
    }
    if (cap.supported === false) {
        return join(lines, "\n") + "\n";
    }
    const survey = getSurveySummary(cap.iface);
    if (length(survey)) {
        lines.push("survey:");
        for (let i = 0; i < length(survey); i++) {
            const s = survey[i];
            lines.push(`  freq=${s.frequency} noise=${s.noise} time=${s.time} busy=${s.time_busy} rx=${s.time_rx} tx=${s.time_tx}`);
        }
    }
    else {
        lines.push("survey: (none)");
    }
    return join(lines, "\n") + "\n";
}

export function formatCaptureReport(result)
{
    const lines = [];
    lines.push(`waterfall ${packageVersion()} capture`);
    if (result.capability) {
        lines.push(trim(formatProbeReport(result.capability)));
    }
    if (!result.ok) {
        lines.push(`ERROR: ${result.error}`);
        return join(lines, "\n") + "\n";
    }
    if (result.experimental) {
        lines.push("NOTE: ath10k capture is experimental (hAP ac lite 5 GHz / PowerBeam 500 AC class).");
    }
    lines.push(`fft_file ${result.fft_file}  bytes ${result.fft_bytes}`);
    lines.push("FFT TLV parse / waterfall display not implemented yet — raw dump saved for analysis.");
    return join(lines, "\n") + "\n";
}
