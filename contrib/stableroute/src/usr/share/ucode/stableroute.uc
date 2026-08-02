/*
 * stableroute — run traceroute N times, group identical hop paths, report stability.
 */

import * as fs from "fs";

/* Keep in sync with build.sh -v/-r (and bump-stableroute-revision rule). */
export function packageVersion()
{
    return "0.1.33-r0";
};

const AREDN_TRACEROUTE = "/usr/bin/aredn-traceroute";
const STOCK_TRACEROUTE = "/bin/traceroute -q 1 -w 1";

/**
 * Prefer aredn-traceroute when installed, unless legacy is true.
 * Does not install packages — only detects /usr/bin/aredn-traceroute.
 * Returns { using, cmd } where using is the header phrase.
 */
export function selectProbe(legacy)
{
    if (!legacy && fs.access(AREDN_TRACEROUTE)) {
        return {
            using: "using aredn-traceroute",
            cmd: AREDN_TRACEROUTE
        };
    }
    return {
        using: "using traceroute",
        cmd: STOCK_TRACEROUTE
    };
};

export function shortMeshName(name)
{
    if (!name) {
        return name;
    }
    return replace(name, /\.local\.mesh$/, "");
};

export function normalizeDest(dest)
{
    if (!dest) {
        return dest;
    }
    if (!match(dest, /\./) && !match(dest, /^[0-9.]+$/)) {
        return `${dest}.local.mesh`;
    }
    return dest;
};

/**
 * True if dest is a plausible IPv4 or resolves via nslookup (not NXDOMAIN).
 * Does not test L3 reachability — only name/address validity.
 */
export function destIsResolvable(dest)
{
    dest = normalizeDest(dest);
    if (!dest) {
        return false;
    }
    const ip = match(dest, /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
    if (ip) {
        for (let i = 1; i <= 4; i++) {
            const n = int(ip[i]);
            if (n < 0 || n > 255) {
                return false;
            }
        }
        return true;
    }
    if (!fs.access("/usr/bin/nslookup")) {
        return true;
    }
    const running = fs.popen(`nslookup ${dest} 2>&1`);
    if (!running) {
        return false;
    }
    let found = false;
    for (let line = running.read("line"); length(line); line = running.read("line")) {
        line = replace(line, /\r?\n$/, "");
        if (match(line, /NXDOMAIN|can't find/i)) {
            running.close();
            return false;
        }
        /* Answer A record: "Address: 10.x.x.x" (not "Address: 127.0.0.1:53"). */
        if (match(line, /^Address:\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
            found = true;
        }
    }
    running.close();
    return found;
};

/**
 * Parse a hop line from BusyBox traceroute or aredn-traceroute enrichment.
 * Returns null if not a hop line.
 */
export function parseHopLine(line)
{
    line = trim(line);
    if (!line) {
        return null;
    }
    /* BusyBox -q 1 prints a single *; -q 3 prints * * *. Accept either. */
    let m = match(line, /^([0-9]+) +\*/);
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

function hopIdentity(hop)
{
    if (!hop || hop.unreachable) {
        return "*";
    }
    const host = shortMeshName(hop.hostname);
    if (host && host !== hop.ip) {
        return lc(host);
    }
    if (hop.ip) {
        return hop.ip;
    }
    return "*";
};

function pathKeyFromHops(hops)
{
    const parts = [];
    for (let i = 0; i < length(hops); i++) {
        push(parts, hopIdentity(hops[i]));
    }
    return join("|", parts);
};

function hopDisplay(hop)
{
    if (!hop || hop.unreachable) {
        return "*";
    }
    const host = shortMeshName(hop.hostname);
    if (host && hop.ip && host !== hop.ip) {
        return `${host} (${hop.ip})`;
    }
    if (hop.ip) {
        return hop.ip;
    }
    return host || "*";
};

function rttNumber(hop)
{
    if (!hop || hop.unreachable || hop.rtt == null || hop.rtt === "") {
        return null;
    }
    const n = hop.rtt * 1;
    if (n != n) {
        return null;
    }
    return n;
};

/**
 * True if any hop matches the destination hostname or IP.
 */
export function runReachedDest(hops, dest)
{
    if (!dest || !hops || length(hops) === 0) {
        return false;
    }
    const destShort = lc(shortMeshName(dest));
    const destIsIp = match(dest, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/);
    for (let i = 0; i < length(hops); i++) {
        const h = hops[i];
        if (!h || h.unreachable) {
            continue;
        }
        if (destIsIp && h.ip === dest) {
            return true;
        }
        if (h.ip && destIsIp === false && h.ip === dest) {
            return true;
        }
        const host = lc(shortMeshName(h.hostname));
        if (host && destShort && host === destShort) {
            return true;
        }
    }
    return false;
};

/**
 * Run one traceroute probe; return { hops, ok, raw, events }.
 * events[i] = { line, hop } where hop is null if the line was not a parsed hop.
 * probeCmd defaults to stock /bin/traceroute.
 * onLine: optional callback after each output line (for progress keepalives).
 */
export function runOneTraceroute(dest, probeCmd, onLine)
{
    dest = normalizeDest(dest);
    const cmd = probeCmd || STOCK_TRACEROUTE;
    const hops = [];
    const raw = [];
    const events = [];
    const running = fs.popen(`${cmd} ${dest} 2>&1`);
    if (!running) {
        return { hops: hops, ok: false, raw: raw, events: events };
    }
    for (let line = running.read("line"); length(line); line = running.read("line")) {
        line = replace(line, /\r?\n$/, "");
        push(raw, line);
        const hop = parseHopLine(line);
        push(events, { line: line, hop: hop });
        if (hop) {
            push(hops, hop);
        }
        if (onLine) {
            onLine();
        }
    }
    running.close();
    return { hops: hops, ok: true, raw: raw, events: events };
};

function absDiff(a, b)
{
    const d = a - b;
    return d < 0 ? -d : d;
};

function roundMs(n)
{
    if (n < 0) {
        return int(n - 0.5);
    }
    return int(n + 0.5);
};

/**
 * Aggregate N traceroute runs.
 * Returns report object used by formatReport.
 */
export function aggregateRuns(dest, runs)
{
    dest = normalizeDest(dest);
    const buckets = {};
    let unreachable = 0;
    let shortest = null;
    let longest = null;
    let totalOk = 0;

    for (let r = 0; r < length(runs); r++) {
        const run = runs[r];
        const hops = run.hops || [];
        const hopCount = length(hops);
        if (shortest == null || hopCount < shortest) {
            shortest = hopCount;
        }
        if (longest == null || hopCount > longest) {
            longest = hopCount;
        }
        const reached = runReachedDest(hops, dest);
        if (!reached) {
            unreachable++;
        }
        const key = pathKeyFromHops(hops);
        let b = buckets[key];
        if (!b) {
            b = {
                key: key,
                count: 0,
                reached: reached,
                hops: hops,
                rtts: []
            };
            for (let i = 0; i < hopCount; i++) {
                push(b.rtts, []);
            }
            buckets[key] = b;
        }
        b.count++;
        /* Once reachable, keep reachable; never flip a reachable path to unreachable. */
        if (reached) {
            b.reached = true;
        }
        /* Prefer a display hop list from a reachable run when possible. */
        if (reached && !b.displayFromReachable) {
            b.hops = hops;
            b.displayFromReachable = true;
        }
        for (let i = 0; i < hopCount; i++) {
            if (i >= length(b.rtts)) {
                push(b.rtts, []);
            }
            const ms = rttNumber(hops[i]);
            if (ms != null) {
                push(b.rtts[i], ms);
            }
        }
        totalOk++;
    }

    const paths = [];
    for (let k in buckets) {
        push(paths, buckets[k]);
    }

    /* Sort by count desc, then key asc. */
    for (let i = 0; i < length(paths); i++) {
        for (let j = i + 1; j < length(paths); j++) {
            const a = paths[i];
            const b = paths[j];
            let swap = false;
            if (b.count > a.count) {
                swap = true;
            }
            else if (b.count === a.count && b.key < a.key) {
                swap = true;
            }
            if (swap) {
                paths[i] = b;
                paths[j] = a;
            }
        }
    }

    return {
        dest: dest,
        runs: length(runs),
        unreachable: unreachable,
        shortest: shortest == null ? 0 : shortest,
        longest: longest == null ? 0 : longest,
        paths: paths,
        totalOk: totalOk
    };
};

export function formatRttStats(samples)
{
    if (!samples || length(samples) === 0) {
        return "-";
    }
    let sum = 0;
    for (let i = 0; i < length(samples); i++) {
        sum += samples[i];
    }
    const avg = sum / length(samples);
    let maxDev = 0;
    for (let i = 0; i < length(samples); i++) {
        const d = absDiff(samples[i], avg);
        if (d > maxDev) {
            maxDev = d;
        }
    }
    return `avg ${roundMs(avg)}ms +- ${roundMs(maxDev)}ms`;
};

export function formatReport(agg)
{
    const lines = [];
    const n = agg.runs;
    const paths = agg.paths;
    const unique = length(paths);
    push(lines, `stableroute(${packageVersion()}): destination ${shortMeshName(agg.dest)}  runs ${n}`);
    push(lines, agg.using || "using traceroute");
    push(lines, "Summary:");
    push(lines, `  unique paths: ${unique}`);
    push(lines, `  shortest route: ${agg.shortest} hops`);
    push(lines, `  longest route: ${agg.longest} hops`);
    push(lines, `  Unreachable: ${agg.unreachable}`);
    if (unique > 0) {
        const top = paths[0];
        const pct = n > 0 ? roundMs((top.count * 100) / n) : 0;
        push(lines, `  most common: ${top.count}/${n} (${pct}%)`);
    }
    else {
        push(lines, "  most common: -");
    }
    push(lines, "");

    for (let p = 0; p < length(paths); p++) {
        const path = paths[p];
        const pct = n > 0 ? roundMs((path.count * 100) / n) : 0;
        let header = `Path ${p + 1}: ${path.count}/${n} (${pct}%)`;
        if (!path.reached) {
            header += "  [unreachable]";
        }
        push(lines, "-------------------------------------------------");
        push(lines, header);
        const hops = path.hops || [];
        for (let i = 0; i < length(hops); i++) {
            const label = hopDisplay(hops[i]);
            const stats = formatRttStats(path.rtts[i]);
            if (label === "*") {
                push(lines, `  ${hops[i].hop} *  ${stats}`);
            }
            else {
                push(lines, `  ${hops[i].hop} ${label}  ${stats}`);
            }
        }
        if (p + 1 < length(paths)) {
            push(lines, "");
        }
    }
    return join("\n", lines) + "\n";
};

/**
 * Format per-run raw vs parse debug for one traceroute result.
 */
export function formatDebugRun(runIndex, runCount, one)
{
    const lines = [];
    push(lines, `=== Run ${runIndex}/${runCount} ===`);
    push(lines, "RAW:");
    const raw = one.raw || [];
    if (length(raw) === 0) {
        push(lines, "  (no output)");
    }
    else {
        for (let i = 0; i < length(raw); i++) {
            push(lines, `  ${raw[i]}`);
        }
    }
    push(lines, "PARSED:");
    const events = one.events || [];
    let kept = 0;
    let dropped = 0;
    for (let i = 0; i < length(events); i++) {
        const ev = events[i];
        const hop = ev.hop;
        if (!hop) {
            /* Banner / non-hop lines are expected; only flag hop-looking lines. */
            const t = trim(ev.line);
            if (match(t, /^[0-9]+\s/)) {
                push(lines, `  DROP  ${ev.line}`);
                dropped++;
            }
            else {
                push(lines, `  skip  ${ev.line}`);
            }
            continue;
        }
        kept++;
        if (hop.unreachable) {
            push(lines, `  KEEP  hop ${hop.hop} id=* (timeout)  key=*`);
        }
        else {
            const id = hopIdentity(hop);
            const label = hopDisplay(hop);
            const rtt = hop.rtt != null ? hop.rtt : "-";
            push(lines, `  KEEP  hop ${hop.hop} ${label}  rtt=${rtt}ms  key=${id}`);
        }
    }
    push(lines, `PATH KEY: ${pathKeyFromHops(one.hops || [])}`);
    push(lines, `  kept=${kept} dropped=${dropped} hop_count=${length(one.hops || [])}`);
    push(lines, "");
    return join("\n", lines);
};

/**
 * Run traceroute N times and return formatted report text.
 * options.debug: when true, prepend per-run raw vs parse dump.
 * options.legacy: force stock /bin/traceroute even if aredn-traceroute is present.
 * options.progress: print/flush status after each run (keeps CGI connections alive).
 * Returns { ok, text }.
 */
export function runStableRoute(dest, n, options)
{
    if (!dest) {
        return { ok: false, text: "No destination\n" };
    }
    dest = normalizeDest(dest);
    if (n == null || n < 1) {
        n = 10;
    }
    n = int(n);
    if (!destIsResolvable(dest)) {
        return {
            ok: false,
            text: `Error: ${shortMeshName(dest)} is unreachable or invalid\n`
        };
    }
    const debug = !!(options && options.debug);
    const legacy = !!(options && options.legacy);
    const progress = !!(options && options.progress);
    const probe = selectProbe(legacy);
    const runs = [];
    let anyOk = false;
    const debugParts = [];

    /* TTY: overwrite one line with \\r. Pipe/CGI: newline keepalives for line readers. */
    const progressNl = !fs.stdout.isatty();

    function writeProgress(s)
    {
        print(s);
        flush();
    }

    if (progress) {
        writeProgress(`probing ${n} run${n === 1 ? "" : "s"} (${probe.using})\n`);
    }
    for (let i = 0; i < n; i++) {
        // Emit at run start (and on each hop below) so a slow traceroute cannot
        // idle past uhttpd network_timeout (~30s) between keepalives.
        if (progress) {
            if (progressNl) {
                writeProgress(`run ${i + 1}/${n}\n`);
            }
            else {
                writeProgress(`\rrun ${i + 1}/${n}    `);
            }
        }
        const one = runOneTraceroute(dest, probe.cmd, progress ? function () {
            if (progressNl) {
                writeProgress(`run ${i + 1}/${n}\n`);
            }
            else {
                writeProgress(`\rrun ${i + 1}/${n}    `);
            }
        } : null);
        if (one.ok) {
            anyOk = true;
        }
        if (debug) {
            push(debugParts, formatDebugRun(i + 1, n, one));
        }
        push(runs, one);
    }
    if (progress && !progressNl) {
        writeProgress("\n");
    }
    const agg = aggregateRuns(dest, runs);
    agg.using = probe.using;
    let text = formatReport(agg);
    if (debug) {
        text = join("\n", debugParts) + "=== REPORT ===\n" + text;
    }
    return { ok: anyOk, text: text };
};
