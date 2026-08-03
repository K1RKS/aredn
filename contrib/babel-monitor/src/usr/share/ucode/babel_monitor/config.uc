/**
 * UCI config load/save for babel-monitor (flash OK for config only).
 */
import * as fs from "fs";
import * as uci from "uci";
import * as common from "babel_monitor.common";

const UCI_PATH = "/etc/config/babel-monitor";

export function defaults()
{
    return {
        enabled: true,
        sample_interval: 10,
        compress: true,
        sync_limit: 500,
        compress_min_bytes: 1024
    };
};

export function loadConfig()
{
    const cfg = defaults();
    try {
        const c = uci.cursor();
        const e = c.get("babel-monitor", "main", "enabled");
        const si = c.get("babel-monitor", "main", "sample_interval");
        const co = c.get("babel-monitor", "main", "compress");
        const sl = c.get("babel-monitor", "main", "sync_limit");
        const cm = c.get("babel-monitor", "main", "compress_min_bytes");
        if (e !== null) {
            cfg.enabled = common.parseBool(e, cfg.enabled);
        }
        if (si !== null) {
            cfg.sample_interval = common.clampInt(si, 5, 300, cfg.sample_interval);
        }
        if (co !== null) {
            cfg.compress = common.parseBool(co, cfg.compress);
        }
        if (sl !== null) {
            cfg.sync_limit = common.clampInt(sl, 50, 2000, cfg.sync_limit);
        }
        if (cm !== null) {
            cfg.compress_min_bytes = common.clampInt(cm, 0, 1048576, cfg.compress_min_bytes);
        }
    }
    catch (err) {
        /* keep defaults */
    }
    return cfg;
};

export function saveConfig(cfg)
{
    const body =
        "config babel-monitor 'main'\n" +
        `\toption enabled '${cfg.enabled ? "on" : "off"}'\n` +
        `\toption sample_interval '${cfg.sample_interval}'\n` +
        `\toption compress '${cfg.compress ? "on" : "off"}'\n` +
        `\toption sync_limit '${cfg.sync_limit}'\n` +
        `\toption compress_min_bytes '${cfg.compress_min_bytes}'\n`;
    fs.writefile(UCI_PATH, body);
    try {
        uci.cursor().load("babel-monitor");
    }
    catch (e) {
    }
    return true;
};

export function applySetting(cfg, key, val)
{
    switch (key) {
    case "sample_interval":
    case "interval":
        cfg.sample_interval = common.clampInt(val, 5, 300, cfg.sample_interval);
        return true;
    case "compress":
        cfg.compress = common.parseBool(val, cfg.compress);
        return true;
    case "enabled":
        cfg.enabled = common.parseBool(val, cfg.enabled);
        return true;
    case "sync_limit":
        cfg.sync_limit = common.clampInt(val, 50, 2000, cfg.sync_limit);
        return true;
    case "compress_min_bytes":
    case "compress_min":
        cfg.compress_min_bytes = common.clampInt(val, 0, 1048576, cfg.compress_min_bytes);
        return true;
    default:
        return false;
    }
};
