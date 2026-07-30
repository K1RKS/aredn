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
    let gpsReason = null;
    if (lat == null || lon == null) {
        gpsReason = "local node has no lat/lon in aredn.@location[0]";
    }
    return storeEntry(ctx, ctx.localKey, {
        key: ctx.localKey,
        local: true,
        failed: false,
        fetchHost: null,
        failReason: null,
        gpsReason: gpsReason,
        displayName: hostname,
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
    const url = `http://${host}/a/sysinfo?lqm=1`;
    const info = fetchJson(url);
    if (!info) {
        return storeEntry(ctx, key, {
            key: key,
            local: false,
            failed: true,
            fetchHost: host,
            failReason: `sysinfo fetch failed (${url}); timeout, unreachable, or non-AREDN hop`,
            gpsReason: `no GPS: sysinfo fetch failed for ${host}`,
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
    let gpsReason = null;
    if (info.lat == null || info.lon == null || info.lat === "" || info.lon === "") {
        gpsReason = `node ${hostname} responded to sysinfo but lat/lon are unset (aredn.@location[0])`;
    }
    const entry = storeEntry(ctx, key, {
        key: key,
        local: false,
        failed: false,
        fetchHost: host,
        failReason: null,
        gpsReason: gpsReason,
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

function isIpv4(s)
{
    return s && match(s, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ? true : false;
}

function hasNeighborIndex(entry)
{
    if (!entry || !entry.byIp) {
        return false;
    }
    for (let k in entry.byIp) {
        return true;
    }
    return false;
}

function rebindEntry(ctx, failedOrOld, good)
{
    if (!failedOrOld || !good) {
        return;
    }
    if (failedOrOld.ip) {
        ctx.byKey[failedOrOld.ip] = good;
        ctx.hostIndex[failedOrOld.ip] = good.key;
    }
    if (failedOrOld.key && failedOrOld.key !== good.key) {
        ctx.byKey[failedOrOld.key] = good;
    }
    if (failedOrOld.displayName) {
        good.displayName = good.displayName || failedOrOld.displayName;
        const dk = cacheKey(failedOrOld.displayName);
        if (dk) {
            ctx.hostIndex[dk] = good.key;
        }
    }
}

/**
 * Prefer LQM from a previous hop entry. If that entry failed (e.g. tunnel IP)
 * but we later learned a mesh hostname for it, re-fetch sysinfo via that hostname
 * (and use its mesh IP / LQM for lookups).
 */
function getLqmSource(ctx, prevKey)
{
    let prev = ctx.byKey[prevKey] || (prevKey === ctx.localKey ? ctx.byKey[ctx.localKey] : null);
    if (!prev) {
        return null;
    }
    if (!prev.failed && hasNeighborIndex(prev)) {
        return prev;
    }
    const altName = prev.displayName;
    if (!altName || isIpv4(altName) || altName === prev.ip) {
        return prev;
    }
    const altKey = cacheKey(altName);
    if (altKey && ctx.byKey[altKey] && !ctx.byKey[altKey].failed) {
        const alt = ctx.byKey[altKey];
        alt.refreshedViaHostname = true;
        alt.displayName = alt.displayName || altName;
        rebindEntry(ctx, prev, alt);
        return alt;
    }
    const alt = ensureNode(ctx, altName);
    if (alt && !alt.failed) {
        alt.refreshedViaHostname = true;
        alt.displayName = alt.displayName || altName;
        rebindEntry(ctx, prev, alt);
        return alt;
    }
    return prev;
}

export function lookupLink(ctx, prevKey, nextIp, nextHost)
{
    const prev = getLqmSource(ctx, prevKey);
    const prevLabel = prev ? (prev.displayName || prev.hostname || prev.ip || prevKey) : prevKey;
    if (!prev) {
        return {
            type: null,
            cost: null,
            typeReason: `no LQM data for previous hop (${prevKey})`,
            costReason: `no LQM data for previous hop (${prevKey})`,
            viaHostname: false
        };
    }
    if (prev.failed) {
        const why = prev.failReason || `previous hop ${prevLabel} sysinfo/LQM unavailable`;
        return {
            type: null,
            cost: null,
            typeReason: `link type unknown: ${why}`,
            costReason: `link cost unknown: ${why}`,
            viaHostname: false
        };
    }
    const tracker = findNeighbor(prev, nextIp, nextHost);
    if (!tracker) {
        const target = nextIp || nextHost || "?";
        const why = `${target} not found as a Babel/LQM neighbor of previous hop ${prevLabel}`;
        return {
            type: null,
            cost: null,
            typeReason: `link type unknown: ${why}`,
            costReason: `link cost unknown: ${why}`,
            viaHostname: prev.refreshedViaHostname ? true : false
        };
    }
    const type = mapLinkType(tracker.type);
    const cost = linkCost(prev, tracker, prev.local);
    return {
        type: type,
        cost: cost,
        typeReason: type ? null : `neighbor ${nextIp || nextHost} on ${prevLabel} has no link type`,
        costReason: cost != null ? null : (
            prev.local
                ? `neighbor on ${prevLabel} has no Babel cost / LQM rxcost`
                : `neighbor on ${prevLabel} has no LQM rxcost/txcost`
        ),
        viaHostname: prev.refreshedViaHostname ? true : false,
        prevLabel: prevLabel,
        neighborHostname: tracker.hostname || null
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
 * Prefer a real nodename when traceroute only showed an IP.
 * Sources: this hop's sysinfo (node), else previous hop's LQM neighbor hostname
 * (refreshing previous hop via its resolved mesh hostname if the traceroute IP failed).
 * Returns { name, source, from }.
 */
function resolveDisplayHostname(ctx, prevKey, hop, node)
{
    let name = hop.hostname;
    if (name && !isIpv4(name) && name !== hop.ip) {
        if (!match(name, /\./)) {
            name = `${name}.local.mesh`;
        }
        return { name: name, source: "traceroute" };
    }

    if (node && node.hostname && !isIpv4(node.hostname) && node.hostname !== hop.ip) {
        name = node.hostname;
        if (!match(name, /\./)) {
            name = `${name}.local.mesh`;
        }
        return { name: name, source: "sysinfo" };
    }

    const prev = getLqmSource(ctx, prevKey);
    if (prev && !prev.failed) {
        const tracker = findNeighbor(prev, hop.ip, hop.hostname);
        if (tracker && tracker.hostname && !isIpv4(tracker.hostname)) {
            name = tracker.hostname;
            if (!match(name, /\./)) {
                name = `${name}.local.mesh`;
            }
            const prevLabel = prev.displayName || prev.hostname || prev.ip || prevKey;
            const source = prev.refreshedViaHostname ? "previous_lqm_via_hostname" : "previous_lqm";
            return { name: name, source: source, from: prevLabel };
        }
    }

    return { name: hop.hostname || hop.ip, source: "unresolved" };
}

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
            notes: [ "    # unreachable hop (* * *); no GPS/link metadata" ],
            nextKey: prevKey
        };
    }
    let node = ensureNode(ctx, hop.ip || hop.hostname);
    // Resolve name first so a failed tunnel-IP prev can be refreshed via its mesh hostname.
    let resolved = resolveDisplayHostname(ctx, prevKey, hop, node);
    // If this hop's IP sysinfo failed but we learned a hostname from prev LQM, re-fetch via name.
    if (node && node.failed && resolved.name && !isIpv4(resolved.name) && resolved.name !== hop.ip) {
        const byName = ensureNode(ctx, resolved.name);
        if (byName && !byName.failed) {
            rebindEntry(ctx, node, byName);
            node = byName;
            if (byName.hostname && !isIpv4(byName.hostname)) {
                const prior = resolved;
                let src = "sysinfo";
                if (prior.source === "previous_lqm" || prior.source === "previous_lqm_via_hostname") {
                    src = "previous_lqm_then_sysinfo";
                }
                resolved = {
                    name: meshHost(byName.hostname) || byName.hostname,
                    source: src,
                    from: prior.from
                };
            }
        }
    }
    const link = lookupLink(ctx, prevKey, hop.ip, hop.hostname);
    // If name still unresolved, try again after prev may have been refreshed via hostname.
    if (resolved.source === "unresolved") {
        resolved = resolveDisplayHostname(ctx, prevKey, hop, node);
    }
    const hostname = resolved.name;
    if (node) {
        node.displayName = hostname;
        if (!isIpv4(hostname) && hostname !== hop.ip) {
            const hk = cacheKey(hostname);
            if (hk) {
                ctx.hostIndex[hk] = node.key;
            }
        }
    }
    const lat = node ? node.lat : null;
    const lon = node ? node.lon : null;
    let nextKey = (node && node.key) ? node.key : (cacheKey(hop.ip || hop.hostname) || prevKey);
    // Prefer mesh-IP/hostname cache key when we rebound a failed tunnel entry.
    if (node && !node.failed && node.ip && hop.ip && node.ip !== hop.ip) {
        nextKey = node.key;
    }
    const tracerouteWasIp = isIpv4(hop.hostname) || hop.hostname === hop.ip || !hop.hostname;
    const notes = [];
    if (resolved.source === "previous_lqm") {
        push(notes, `    # name: ${hostname} from previous hop ${resolved.from} LQM neighbor list`);
    }
    else if (resolved.source === "previous_lqm_via_hostname") {
        push(notes, `    # name: ${hostname} from previous hop ${resolved.from} LQM (refetched via mesh hostname after traceroute IP failed)`);
    }
    else if (resolved.source === "previous_lqm_then_sysinfo") {
        push(notes, `    # name: ${hostname} from previous hop ${resolved.from} LQM, then confirmed via hop sysinfo`);
    }
    else if (resolved.source === "sysinfo" && tracerouteWasIp) {
        push(notes, `    # name: ${hostname} from hop sysinfo (traceroute only had IP)`);
    }
    else if (resolved.source === "unresolved") {
        push(notes, `    # name: no hostname from sysinfo or previous hop LQM for ${hop.ip || hop.hostname}`);
    }
    if (link.viaHostname) {
        push(notes, `    # link: previous hop LQM loaded via resolved hostname ${link.prevLabel}`);
    }
    if (lat == null || lon == null || lat === "" || lon === "") {
        if (node && node.gpsReason) {
            push(notes, `    # GPS -: ${node.gpsReason}`);
        }
        else if (!node) {
            push(notes, "    # GPS -: could not resolve hop for sysinfo lookup");
        }
        else {
            push(notes, "    # GPS -: lat/lon unavailable");
        }
    }
    if (!link.type && link.typeReason) {
        push(notes, `    # type -: ${link.typeReason}`);
    }
    if (link.cost == null && link.costReason) {
        push(notes, `    # cost -: ${link.costReason}`);
    }
    return {
        line: formatHopLine(hop.hop, hostname, hop.ip, hop.rtt, lat, lon, link.type, link.cost),
        notes: notes,
        nextKey: nextKey
    };
};

/**
 * Run traceroute and emit lines via printFn(line).
 * options.verbose: when true, print why unset GPS/type/cost values are missing.
 * Returns true on success.
 */
export function runEnrichedTraceroute(dest, printFn, options)
{
    if (!dest) {
        return false;
    }
    if (!match(dest, /\./) && !match(dest, /^[0-9.]+$/)) {
        dest = `${dest}.local.mesh`;
    }
    const verbose = !!(options && options.verbose);
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
            if (verbose) {
                const notes = enriched.notes || [];
                for (let i = 0; i < length(notes); i++) {
                    printFn(notes[i]);
                }
            }
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
