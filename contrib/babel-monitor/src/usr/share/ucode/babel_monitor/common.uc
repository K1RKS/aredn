/**
 * babel-monitor common helpers
 */
import * as math from "math";

export function packageVersion()
{
    return "0.1.66-r0";
};

/**
 * Public CGI/JSON wire contract for central pollers.
 * Bump when endpoints, query params, or response fields change in a way
 * that clients must adapt (independent of SCHEMA_VERSION / packageVersion).
 */
export const API_VERSION = 2;
export const SCHEMA_VERSION = 9;
export const SOCK_PATH = "/var/run/babel-monitor.sock";
export const RUN_DIR = "/var/run/babel-monitor";
/** Max sample slots (24h @ 10s). Actual capacity comes from UCI ring_size. */
export const SAMPLE_CAP_MAX = 8640;
/** Legacy alias: 4h @ 10s (default preset). */
export const SAMPLE_CAP = 1440;
export const EVENT_CAP = 512;
export const RF_NEIGHBOR_CAP = 12; /* per-sample RF pairs (RAM bound) */
export const LINK_IO_CAP = 12; /* per-sample link triples (RAM bound) */
export const COST_NEIGHBOR_CAP = 12; /* per-sample neighbor cost pairs (RAM bound) */
export const LABEL_CAP = 64; /* shared name dictionary for rf/links/costs */
export const SERIES_SLICE_S = 300; /* max expand window per series request (5m) */
export const SERIES_END_AGE_MAX = 86400; /* allow series end_age through 24h ring */
export const RETENTION_S_AT_DEFAULT = SAMPLE_CAP * 10;
/** Estimate: ucode boxed int ≈ 12 bytes (matches store.estimateBytes). */
export const INT_ESTIMATE_BYTES = 12;
/** Canonical ring presets (slot counts assume default 10s sample interval). */
export const RING_SIZE_IDS = [ "none", "5m", "30m", "1h", "4h", "24h" ];

/** Match firmware mgr/babel_monitor.uc hard-reset candidate thresholds (observe only). */
export const STUCK_COST = 65535;
export const STUCK_MIN_LQ = 50;

/**
 * Dense sample vector layout (schema 9) — fixed width, mutated in place:
 *  0 t, 1 seq,
 *  2 neighbor_count, 3 routable_count,
 *  4 route_count_20, 5 route_count_21, 6 route_count_22,
 *  7 mean_lq, 8 min_lq, 9 mean_cost, 10 bad_cost_count,
 *  11 neighbor_add, 12 neighbor_remove,
 *  13 tx_packets_delta, 14 tx_retries_delta, 15 tx_fail_delta,
 *  16 mean_snr, 17 mean_tx_bitrate,
 *  18 host_count, 19 host_change_delta,
 *  20 dns_reload_delta, 21 babel_hard_delta, 22 babel_soft_delta,
 *  23 uptime_s, 24 reboot_delta,
 *  25 mem_used_pct, 26 mem_available_kb,
 *  27 cpu_pct, 28 cpu_peak_pct,
 *  29 lqm_ok, 30 babel_ok,
 *  31 rx_packets_delta, 32 daemon_rss_kb,
 *  33 rf_count, 34 link_count, 35 stuck_neighbor_count, 36 cost_count,
 *  then RF_NEIGHBOR_CAP pairs (label_idx, snr),
 *  then LINK_IO_CAP triples (label_idx, tx, rx),
 *  then COST_NEIGHBOR_CAP pairs (label_idx, cost).
 */
export const SAMPLE_HDR = 37;
export const SAMPLE_WIDTH = SAMPLE_HDR
    + RF_NEIGHBOR_CAP * 2
    + LINK_IO_CAP * 3
    + COST_NEIGHBOR_CAP * 2;

export function normalizeRingSize(v)
{
    const s = lc(trim(`${v || ""}`));
    if (s === "none" || s === "0" || s === "off") {
        return "none";
    }
    if (s === "5m" || s === "5min" || s === "300") {
        return "5m";
    }
    if (s === "30m" || s === "30min" || s === "1800") {
        return "30m";
    }
    if (s === "1h" || s === "60m" || s === "3600") {
        return "1h";
    }
    if (s === "4h" || s === "240m" || s === "14400") {
        return "4h";
    }
    if (s === "24h" || s === "1d" || s === "86400") {
        return "24h";
    }
    return "4h";
};

/** Slots for a ring_size id (0 = no history buffer). */
export function ringSlots(id)
{
    const s = normalizeRingSize(id);
    if (s === "none") {
        return 0;
    }
    if (s === "5m") {
        return 30;
    }
    if (s === "30m") {
        return 180;
    }
    if (s === "1h") {
        return 360;
    }
    if (s === "24h") {
        return 8640;
    }
    return 1440; /* 4h */
};

/** Nominal wall-time depth @ 10s interval. */
export function ringSeconds(id)
{
    return ringSlots(id) * 10;
};

/** Dense sample-buffer bytes only (no event ring / overhead). */
export function ringBufferBytes(id)
{
    return ringSlots(id) * SAMPLE_WIDTH * INT_ESTIMATE_BYTES;
};

/**
 * Pick initial ring_size from MemAvailable (kB) at package install.
 * Thresholds: <2MB none; ≤4MB 5m; ≤6MB 1h; ≤30MB 4h; else 24h.
 * (30m is manual-only — not auto-selected.)
 */
export function pickRingSizeFromFreeKb(avail_kb)
{
    const a = int(avail_kb);
    if (a < 2048) {
        return "none";
    }
    if (a <= 4096) {
        return "5m";
    }
    if (a <= 6144) {
        return "1h";
    }
    if (a <= 30720) {
        return "4h";
    }
    return "24h";
};

/** Display label for babel/LQM ifaces (br0.N → XLink(N)). */
export function formatIfaceLabel(iface)
{
    if (!iface) {
        return "";
    }
    const m = match(`${iface}`, /^br0\.([0-9]+)$/);
    if (m) {
        return sprintf("XLink(%s)", m[1]);
    }
    return `${iface}`;
};

/**
 * Neighbor link type for live UI (not stored in the sample ring).
 * WG: wgc* = server (WG-S), wgs* = client (WG-C).
 */
export function linkTypeLabel(iface)
{
    if (!iface) {
        return "—";
    }
    const d = `${iface}`;
    if (d === "br-dtdlink") {
        return "DtD";
    }
    if (match(d, /^wgc/)) {
        return "WG-S";
    }
    if (match(d, /^wgs/)) {
        return "WG-C";
    }
    if (match(d, /^wg/)) {
        return "WG";
    }
    const xm = match(d, /^br0\.([0-9]+)$/);
    if (xm) {
        return sprintf("XLink(%s)", xm[1]);
    }
    if (match(d, /^wlan/)) {
        return "RF";
    }
    if (d === "br-wifi" || d === "br-fast") {
        return "RRF";
    }
    return d;
};

export function parseBool(v, dflt)
{
    if (v == null || v === "") {
        return dflt;
    }
    const s = lc(`${v}`);
    if (s === "1" || s === "on" || s === "true" || s === "yes") {
        return true;
    }
    if (s === "0" || s === "off" || s === "false" || s === "no") {
        return false;
    }
    return dflt;
};

export function clampInt(v, lo, hi, dflt)
{
    const n = int(v);
    if (n === null || n != n) {
        return dflt;
    }
    if (n < lo) {
        return lo;
    }
    if (n > hi) {
        return hi;
    }
    return n;
};

/** Wall-clock Unix seconds (for sample/event t and series windows). */
export function nowUnix()
{
    return int(clock()[0]);
};

export function bootIdNew()
{
    return sprintf("%d-%d", nowUnix(), math.rand() % 1000000);
};
