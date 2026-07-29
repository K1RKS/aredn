/*
 * AREDN traceroute with per-hop mesh metadata (GPS, link type, Babel cost).
 * Side-loaded package companion for AREDN firmware.
 *
 * Attribution: AREDN project patterns and APIs.
 */

import * as fs from "fs";
import * as uci from "uci";
import * as babel from "aredn.babel";
import * as configuration from "aredn.configuration";

const UFETCH = "/bin/uclient-fetch";
const FETCH_TIMEOUT = 2;

function toNum(v)
{
    if (v == null || v === "") {
        return null;
    }
    const n = +v;
    if (n != n) {
        return null;
    }
    return n;
}

function meshHost(name)
{
    if (!name || name === "*") {
        return null;
    }
    if (match(name, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
        return name;
    }
    if (!match(name, /\./)) {
        return `${name}.local.mesh`;
    }
    return name;
}

function mapLinkType(type)
{
    if (!type) {
        return null;
    }
    switch (type) {
        case "DtD":
        case "DTD":
            return "DtD";
        case "RF":
        case "RRF":
        case "LRF":
            return "RF";
        case "Wireguard":
        case "WIREGUARD":
        case "WG":
            return "WG";
        case "Xlink":
        case "XLINK":
            return "Xlink";
        default:
            return type;
    }
}

function trackerIps(tracker)
{
    const ips = [];
    if (tracker.ip) {
        push(ips, tracker.ip);
    }
    if (tracker.canonical_ip && tracker.canonical_ip !== tracker.ip) {
        push(ips, tracker.canonical_ip);
    }
    return ips;
}

function indexTrackers(trackers)
{
    const byIp = {};
    const byHost = {};
    if (!trackers) {
        return { byIp: byIp, byHost: byHost };
    }
    for (let mac in trackers) {
        const t = trackers[mac];
        if (!t) {
            continue;
        }
        const ips = trackerIps(t);
        for (let i = 0; i < length(ips); i++) {
            byIp[ips[i]] = t;
        }
        if (t.hostname) {
            byHost[lc(t.hostname)] = t;
            const short = match(t.hostname, /^([^.]+)/);
            if (short) {
                byHost[lc(short[1])] = t;
            }
        }
    }
    return { byIp: byIp, byHost: byHost };
}

function findNeighbor(entry, nextIp, nextHost)
{
    if (!entry || entry.failed) {
        return null;
    }
    if (nextIp && entry.byIp[nextIp]) {
        return entry.byIp[nextIp];
    }
    if (nextHost) {
        const h = lc(replace(nextHost, /\.local\.mesh$/, ""));
        if (entry.byHost[h]) {
            return entry.byHost[h];
        }
        if (entry.byHost[lc(nextHost)]) {
            return entry.byHost[lc(nextHost)];
        }
    }
    return null;
}

function localBabelCost(device)
{
    if (!device) {
        return null;
    }
    try {
        const neighbors = babel.getNeighbors();
        for (let i = 0; i < length(neighbors); i++) {
            const n = neighbors[i];
            if (n.interface === device && n.cost != null) {
                return n.cost;
            }
        }
    }
    catch (_) {
    }
    return null;
}

function linkCost(entry, tracker, local)
{
    if (!tracker) {
        return null;
    }
    if (local) {
        const c = localBabelCost(tracker.device);
        if (c != null) {
            return c;
        }
    }
    if (tracker.rxcost != null) {
        return tracker.rxcost;
    }
    if (tracker.txcost != null) {
        return tracker.txcost;
    }
    return null;
}

export function createContext()
{
    return {
        byKey: {},
        hostIndex: {},
        localKey: "local"
    };
};

function storeEntry(ctx, key, entry)
{
    ctx.byKey[key] = entry;
    if (entry.hostname) {
        ctx.hostIndex[lc(entry.hostname)] = key;
        const short = match(entry.hostname, /^([^.]+)/);
        if (short) {
            ctx.hostIndex[lc(short[1])] = key;
        }
    }
    if (entry.ip) {
        ctx.hostIndex[entry.ip] = key;
    }
    return entry;
}

function cacheKey(hostOrIp)
{
    if (!hostOrIp) {
        return null;
    }
    if (match(hostOrIp, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
        return hostOrIp;
    }
    return lc(replace(hostOrIp, /\.local\.mesh$/, ""));
}

export function seedLocal(ctx)
{
    let trackers = {};
    let lat = null;
    let lon = null;
    let hostname = null;
    try {
        hostname = configuration.getName();
    }
    catch (_) {
    }
    try {
        const c = uci.cursor();
        lat = toNum(c.get("aredn", "@location[0]", "lat"));
        lon = toNum(c.get("aredn", "@location[0]", "lon"));
    }
    catch (_) {
    }
    try {
        if (fs.access("/tmp/lqm.info")) {
            const lqm = json(fs.readfile("/tmp/lqm.info"));
            trackers = lqm.trackers || {};
        }
    }
    catch (_) {
    }
    const idx = indexTrackers(trackers);
    return storeEntry(ctx, ctx.localKey, {
        key: ctx.localKey,
        local: true,
        failed: false,
        lat: lat,
        lon: lon,
        hostname: hostname,
        ip: null,
        trackers: trackers,
        byIp: idx.byIp,
        byHost: idx.byHost
    });
};

function fetchJson(url)
{
    const p = fs.popen(`${UFETCH} -T ${FETCH_TIMEOUT} "${url}" -O - 2> /dev/null`);
    if (!p) {
        return null;
    }
    let body = "";
    for (let chunk = p.read("line"); length(chunk); chunk = p.read("line")) {
        body += chunk;
    }
    p.close();
    if (!body) {
        return null;
    }
    try {
        return json(body);
    }
    catch (_) {
        return null;
    }
}

export function ensureNode(ctx, hostOrIp)
{
    const key = cacheKey(hostOrIp);
    if (!key) {
        return null;
    }
    if (ctx.byKey[key]) {
        return ctx.byKey[key];
    }
    if (ctx.hostIndex[key] && ctx.byKey[ctx.hostIndex[key]]) {
        return ctx.byKey[ctx.hostIndex[key]];
    }

    const host = meshHost(hostOrIp);
    const info = fetchJson(`http://${host}/a/sysinfo?lqm=1`);
    if (!info) {
        return storeEntry(ctx, key, {
            key: key,
            local: false,
            failed: true,
            lat: null,
            lon: null,
            hostname: hostOrIp,
            ip: match(hostOrIp, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ? hostOrIp : null,
            trackers: {},
            byIp: {},
            byHost: {}
        });
    }

    const trackers = (info.lqm && info.lqm.info && info.lqm.info.trackers) ? info.lqm.info.trackers : {};
    const idx = indexTrackers(trackers);
    const ip = info.ip || (match(hostOrIp, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ? hostOrIp : null);
    const hostname = info.node || info.hostname || hostOrIp;
    const entry = storeEntry(ctx, key, {
        key: key,
        local: false,
        failed: false,
        lat: info.lat,
        lon: info.lon,
        hostname: hostname,
        ip: ip,
        trackers: trackers,
        byIp: idx.byIp,
        byHost: idx.byHost
    });
    if (ip && ip !== key) {
        ctx.byKey[ip] = entry;
        ctx.hostIndex[ip] = key;
    }
    return entry;
};

export function lookupLink(ctx, prevKey, nextIp, nextHost)
{
    const prev = ctx.byKey[prevKey] || (prevKey === ctx.localKey ? seedLocal(ctx) : null);
    if (!prev) {
        return { type: null, cost: null };
    }
    const tracker = findNeighbor(prev, nextIp, nextHost);
    if (!tracker) {
        return { type: null, cost: null };
    }
    return {
        type: mapLinkType(tracker.type),
        cost: linkCost(prev, tracker, prev.local)
    };
};

export function formatGps(lat, lon)
{
    if (lat == null || lon == null || lat === "" || lon === "") {
        return "-";
    }
    return `${lat},${lon}`;
};

export function formatHopLine(hopNum, hostname, ip, rtt, lat, lon, type, cost)
{
    const host = hostname || ip || "?";
    const ipPart = ip ? ` (${ip})` : "";
    const rttPart = rtt != null ? ` ${rtt} ms` : "";
    const gps = formatGps(lat, lon);
    const t = type || "-";
    const c = cost != null ? `${cost}` : "-";
    return ` ${hopNum}  ${host}${ipPart} ${rttPart}  ${gps}  ${t}  ${c}`;
};

/**
 * Parse a busybox traceroute hop line.
 * Returns null if not a hop line.
 */
export function parseHopLine(line)
{
    line = trim(line);
    if (!line) {
        return null;
    }
    let m = match(line, /^([0-9]+) +\* +\* +\*/);
    if (m) {
        return { hop: int(m[1]), unreachable: true };
    }
    m = match(line, /^([0-9]+) +([^ ]+) \(([0-9.]+)\) +([0-9.]+) +ms/);
    if (m) {
        return {
            hop: int(m[1]),
            hostname: m[2],
            ip: m[3],
            rtt: m[4],
            unreachable: false
        };
    }
    m = match(line, /^([0-9]+) +([0-9.]+) +([0-9.]+) +ms/);
    if (m) {
        return {
            hop: int(m[1]),
            hostname: m[2],
            ip: m[2],
            rtt: m[3],
            unreachable: false
        };
    }
    return null;
};

export function enrichHop(ctx, prevKey, hop)
{
    if (hop.unreachable) {
        return {
            line: ` ${hop.hop}  * * *`,
            nextKey: prevKey
        };
    }
    const node = ensureNode(ctx, hop.ip || hop.hostname);
    const link = lookupLink(ctx, prevKey, hop.ip, hop.hostname);
    let hostname = hop.hostname;
    if (hostname && !match(hostname, /\./) && !match(hostname, /^[0-9.]+$/)) {
        hostname = `${hostname}.local.mesh`;
    }
    const lat = node ? node.lat : null;
    const lon = node ? node.lon : null;
    const nextKey = (node && node.key) ? node.key : (cacheKey(hop.ip || hop.hostname) || prevKey);
    return {
        line: formatHopLine(hop.hop, hostname, hop.ip, hop.rtt, lat, lon, link.type, link.cost),
        nextKey: nextKey
    };
};

/**
 * Run traceroute and emit lines via printFn(line). Returns true on success.
 */
export function runEnrichedTraceroute(dest, printFn)
{
    if (!dest) {
        return false;
    }
    if (!match(dest, /\./) && !match(dest, /^[0-9.]+$/)) {
        dest = `${dest}.local.mesh`;
    }
    const ctx = createContext();
    seedLocal(ctx);
    let prevKey = ctx.localKey;

    const running = fs.popen(`/bin/traceroute -q 1 -w 1 ${dest} 2>&1`);
    if (!running) {
        return false;
    }
    for (let line = running.read("line"); length(line); line = running.read("line")) {
        line = replace(line, /\r?\n$/, "");
        const hop = parseHopLine(line);
        if (hop) {
            const enriched = enrichHop(ctx, prevKey, hop);
            printFn(enriched.line);
            if (!hop.unreachable) {
                prevKey = enriched.nextKey;
            }
        }
        else {
            printFn(line);
        }
    }
    running.close();
    return true;
};
