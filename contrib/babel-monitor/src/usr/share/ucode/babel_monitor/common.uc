/**
 * babel-monitor common helpers
 */
import * as math from "math";

export function packageVersion()
{
    return "0.1.41-r0";
};

/**
 * Public CGI/JSON wire contract for central pollers.
 * Bump when endpoints, query params, or response fields change in a way
 * that clients must adapt (independent of SCHEMA_VERSION / packageVersion).
 */
export const API_VERSION = 1;
export const SCHEMA_VERSION = 7;
export const SOCK_PATH = "/var/run/babel-monitor.sock";
export const RUN_DIR = "/var/run/babel-monitor";
export const SAMPLE_CAP = 1440;  /* 4h @ 10s */
export const EVENT_CAP = 512;
export const RF_NEIGHBOR_CAP = 12; /* per-sample RF pairs (RAM bound) */
export const LINK_IO_CAP = 12; /* per-sample link triples (RAM bound) */
export const LABEL_CAP = 64; /* shared name dictionary for rf/links */
export const SERIES_SLICE_S = 300; /* max expand window per series request (5m) */
export const RETENTION_S_AT_DEFAULT = SAMPLE_CAP * 10;

/**
 * Dense sample vector layout (schema 7) — fixed width, mutated in place:
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
 *  33 rf_count, 34 link_count,
 *  then RF_NEIGHBOR_CAP pairs (label_idx, snr),
 *  then LINK_IO_CAP triples (label_idx, tx, rx).
 */
export const SAMPLE_HDR = 35;
export const SAMPLE_WIDTH = SAMPLE_HDR + RF_NEIGHBOR_CAP * 2 + LINK_IO_CAP * 3;

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
