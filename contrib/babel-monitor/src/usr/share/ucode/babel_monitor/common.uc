/**
 * babel-monitor common helpers
 */
import * as math from "math";

export function packageVersion()
{
    return "0.1.13-r0";
};

export const SCHEMA_VERSION = 4;
export const SOCK_PATH = "/var/run/babel-monitor.sock";
export const RUN_DIR = "/var/run/babel-monitor";
export const SAMPLE_CAP = 1440;  /* 4h @ 10s */
export const EVENT_CAP = 512;
export const RF_NEIGHBOR_CAP = 12; /* per-sample RF SNR map size (RAM bound) */
export const RETENTION_S_AT_DEFAULT = SAMPLE_CAP * 10;

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

export function nowUnix()
{
    return int(clock(true)[0]);
};

export function bootIdNew()
{
    return sprintf("%d-%d", nowUnix(), math.rand() % 1000000);
};
