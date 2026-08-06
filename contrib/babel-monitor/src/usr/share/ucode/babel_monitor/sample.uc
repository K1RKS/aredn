/**
 * Collect one sample from LQM / babel / arednlink (no flash writes).
 */
import * as fs from "fs";
import * as socket from "socket";
import * as uci from "uci";
import * as common from "babel_monitor.common";
import * as storelib from "babel_monitor.store";

const BABEL_SOCK = { path: "/var/run/babel.sock" };

function babelDump(cmd)
{
    const c = socket.connect(BABEL_SOCK);
    if (!c) {
        return null;
    }
    c.send(`${cmd}\nquit\n`);
    let d = "";
    /* Bound reads so a stuck babel.sock cannot grow forever in monitord */
    for (let n = 0; n < 256; n++) {
        const v = c.recv(8192);
        if (!v || v === "") {
            break;
        }
        d += v;
        if (length(d) > 1048576) {
            break;
        }
    }
    c.close();
    return split(d, "\n");
}

function readJsonFile(path)
{
    const raw = fs.readfile(path);
    if (!raw || raw === "") {
        return null;
    }
    try {
        return json(raw);
    }
    catch (e) {
        return null;
    }
}

function countArednlinkHosts()
{
    let n = 0;
    const dir = fs.opendir("/var/run/arednlink/hosts");
    if (!dir) {
        return 0;
    }
    for (;;) {
        const e = dir.read();
        if (!e) {
            break;
        }
        if (e !== "." && e !== "..") {
            n++;
        }
    }
    dir.close();
    return n;
}

/**
 * WireGuard tunnel counts from /etc/config.mesh/wireguard + latest-handshakes.
 * UCI type "client" = server tunnels on this node (wgc*); "server" = client tunnels (wgs*).
 * total = config entries; active = enabled=1; live = handshake within 300s.
 */
function readWgTunnelStats()
{
    const out = {
        server_tunnels: { live: 0, active: 0, total: 0 },
        clients: { live: 0, active: 0, total: 0 }
    };
    let cm = null;
    try {
        cm = uci.cursor("/etc/config.mesh");
    }
    catch (e) {
        return out;
    }
    if (!cm) {
        return out;
    }

    const live_keys = [];
    if (fs.access("/usr/bin/wg")) {
        const w = fs.popen("/usr/bin/wg show all latest-handshakes 2>/dev/null");
        if (w) {
            const now = time();
            for (let line = w.read("line"); length(line); line = w.read("line")) {
                const v = split(trim(line), /\t/);
                if (v && length(v) >= 3 && int(v[2]) + 300 > now) {
                    push(live_keys, v[1]);
                }
            }
            w.close();
        }
    }

    function keyIsLive(key)
    {
        if (!key || key === "") {
            return false;
        }
        for (let i = 0; i < length(live_keys); i++) {
            if (index(key, live_keys[i]) >= 0) {
                return true;
            }
        }
        return false;
    }

    cm.foreach("wireguard", "client", function (s) {
        out.server_tunnels.total++;
        if (s.enabled === "1") {
            out.server_tunnels.active++;
        }
        if (keyIsLive(s.key)) {
            out.server_tunnels.live++;
        }
    });
    cm.foreach("wireguard", "server", function (s) {
        out.clients.total++;
        if (s.enabled === "1") {
            out.clients.active++;
        }
        if (keyIsLive(s.key)) {
            out.clients.live++;
        }
    });
    return out;
}

function resolveIdentity()
{
    let node_id = "";
    let mac = "";
    let hostname = "";

    try {
        const c = uci.cursor();
        node_id = c.get("network", "mesh", "ipaddr") || "";
        hostname = c.get("system", "@system[0]", "hostname") || fs.readfile("/proc/sys/kernel/hostname") || "";
        hostname = trim(hostname);
    }
    catch (e) {
        hostname = trim(fs.readfile("/proc/sys/kernel/hostname") || "");
    }

    for (let ifn in ["br-mesh", "br-dtdlink", "wlan0"]) {
        const p = `/sys/class/net/${ifn}/address`;
        if (fs.access(p)) {
            mac = trim(fs.readfile(p) || "");
            if (mac) {
                break;
            }
        }
    }

    if (!node_id) {
        const p = fs.popen("ip -4 -o addr show scope global 2>/dev/null");
        if (p) {
            for (let line = p.read("line"); length(line); line = p.read("line")) {
                const m = match(line, /inet (10\.[0-9.]+)/);
                if (m) {
                    node_id = m[1];
                    break;
                }
            }
            p.close();
        }
    }

    return { node_id, mac, hostname: trim(hostname) };
}

function babelPid()
{
    const f = fs.readfile("/var/run/babeld.pid");
    if (!f) {
        return null;
    }
    return int(trim(f));
}

/** Read interface TX/RX packet counters from sysfs (null if device missing). */
function readDevCounters(dev)
{
    if (!dev || dev === "") {
        return null;
    }
    const tp = `/sys/class/net/${dev}/statistics/tx_packets`;
    if (!fs.access(tp)) {
        return null;
    }
    const tx = int(trim(fs.readfile(tp) || "0"));
    const rx = int(trim(fs.readfile(`/sys/class/net/${dev}/statistics/rx_packets`) || "0"));
    return { tx: tx || 0, rx: rx || 0 };
}

function linkLabelForTracker(tr, mac, device)
{
    if (tr.type === "RF") {
        if (tr.hostname && tr.hostname !== "") {
            return `${tr.hostname}`;
        }
        if (tr.canonical_ip && tr.canonical_ip !== "") {
            return `${tr.canonical_ip}`;
        }
        return `${mac}`;
    }
    const lab = common.formatIfaceLabel(device);
    if (lab && lab !== "") {
        return lab;
    }
    if (tr.hostname && tr.hostname !== "") {
        return `${tr.hostname}`;
    }
    return device ? `${device}` : `${mac}`;
}

function readUptimeS()
{
    const raw = fs.readfile("/proc/uptime");
    if (!raw) {
        return 0;
    }
    const parts = split(trim(raw), " ");
    return int(parts[0]);
}

function readMemInfo()
{
    const raw = fs.readfile("/proc/meminfo");
    let total = 0;
    let available = 0;
    let free = 0;
    let buffers = 0;
    let cached = 0;
    if (!raw) {
        return { total_kb: 0, available_kb: 0, used_pct: 0 };
    }
    const lines = split(raw, "\n");
    for (let i = 0; i < length(lines); i++) {
        const m = match(lines[i], /^([^:]+):\s+(\d+)/);
        if (!m) {
            continue;
        }
        const k = m[1];
        const v = int(m[2]);
        if (k === "MemTotal") {
            total = v;
        }
        else if (k === "MemAvailable") {
            available = v;
        }
        else if (k === "MemFree") {
            free = v;
        }
        else if (k === "Buffers") {
            buffers = v;
        }
        else if (k === "Cached") {
            cached = v;
        }
    }
    if (!available) {
        available = free + buffers + cached;
    }
    let used_pct = 0;
    if (total > 0) {
        used_pct = int(0.5 + 100 * (total - available) / total);
        if (used_pct < 0) {
            used_pct = 0;
        }
        if (used_pct > 100) {
            used_pct = 100;
        }
    }
    return { total_kb: total, available_kb: available, used_pct: used_pct };
}

/** Aggregate CPU jiffies from /proc/stat first line */
function readCpuStat()
{
    const raw = fs.readfile("/proc/stat");
    if (!raw) {
        return null;
    }
    const line = split(raw, "\n")[0];
    const m = match(line, /^cpu\s+(.+)$/);
    if (!m) {
        return null;
    }
    const parts = split(trim(m[1]), /\s+/);
    let total = 0;
    for (let i = 0; i < length(parts); i++) {
        total += int(parts[i]);
    }
    /* idle = idle + iowait when present */
    const idle = int(parts[3] || 0) + int(parts[4] || 0);
    return { total: total, idle: idle };
}

function cpuPctFromDelta(prev, cur)
{
    if (!prev || !cur) {
        return 0;
    }
    const dt = cur.total - prev.total;
    if (dt <= 0) {
        return 0;
    }
    const didle = cur.idle - prev.idle;
    let pct = int(0.5 + 100 * (dt - didle) / dt);
    if (pct < 0) {
        pct = 0;
    }
    if (pct > 100) {
        pct = 100;
    }
    return pct;
}

/** babel-monitord VmRSS (kB) — /proc/self while sampling in-daemon. */
function readDaemonRssKb()
{
    const raw = fs.readfile("/proc/self/status");
    if (!raw) {
        return null;
    }
    const m = match(raw, /VmRSS:\s+([0-9]+)/);
    if (!m) {
        return null;
    }
    return int(m[1]);
}

/**
 * 1s peak sampler — call from daemon timer between samples.
 * Updates store.last.cpu_peak_pct with max busy% over short windows.
 */
export function updateCpuPeak(store)
{
    const cur = readCpuStat();
    if (!cur) {
        return;
    }
    if (store.last.cpu_peak_total !== null) {
        const pct = cpuPctFromDelta(
            { total: store.last.cpu_peak_total, idle: store.last.cpu_peak_idle },
            cur
        );
        if (pct > store.last.cpu_peak_pct) {
            store.last.cpu_peak_pct = pct;
        }
    }
    store.last.cpu_peak_total = cur.total;
    store.last.cpu_peak_idle = cur.idle;
};

export function refreshIdentity(store)
{
    store.identity = resolveIdentity();
};

export function collectSample(store, cfg)
{
    const t = common.nowUnix();
    let neighbor_count = 0;
    let routable_count = 0;
    let route20 = 0;
    let route21 = 0;
    let route22 = 0;
    let lq_sum = 0;
    let lq_min = 100;
    let cost_sum = 0;
    let cost_n = 0;
    let bad_cost = 0;
    let babel_ok = false;
    let lqm_ok = false;

    let tx_retries = 0;
    let tx_fail = 0;
    let snr_sum = 0;
    let snr_n = 0;
    let br_sum = 0;
    let br_n = 0;

    const neigh_lines = babelDump("dump-neighbors");
    const live = [];
    const new_keys = {};
    let neighbor_add = 0;
    let neighbor_remove = 0;

    /* LQM first so we can attach hostnames to babel neighbors by ipv6ll */
    const host_by_ll = {};
    const lqm = readJsonFile("/tmp/lqm.info");
    if (lqm && lqm.trackers) {
        lqm_ok = true;
        for (let mac in lqm.trackers) {
            const tr = lqm.trackers[mac];
            if (tr.ipv6ll && tr.hostname) {
                host_by_ll[tr.ipv6ll] = tr.hostname;
            }
        }
    }

    /* Unique mesh devices for aggregate iface TX/RX (avoids double-counting) */
    const devices = {};
    if (lqm && lqm.trackers) {
        for (let mac in lqm.trackers) {
            const tr = lqm.trackers[mac];
            if (tr.device) {
                devices[tr.device] = true;
            }
        }
    }

    if (neigh_lines) {
        babel_ok = true;
        const re = /address ([^ ]+) if ([^ ]+) reach ([^ ]+) .+ rxcost ([^ ]+) txcost ([^ ]+).* cost (.+)/;
        for (let i = 0; i < length(neigh_lines); i++) {
            const m = match(neigh_lines[i], re);
            if (!m) {
                continue;
            }
            neighbor_count++;
            const cost = int(m[6]);
            const reach = hex(m[3]);
            let bits = 0;
            for (let b = 1; b < 0x10000; b = b << 1) {
                if (reach & b) {
                    bits++;
                }
            }
            const lq = int(0.5 + 100 * bits / 16);
            lq_sum += lq;
            if (lq < lq_min) {
                lq_min = lq;
            }
            cost_sum += cost;
            cost_n++;
            if (cost === 65535) {
                bad_cost++;
            }
            const key = `${m[1]}|${m[2]}`;
            new_keys[key] = true;
            if (!store.last.neighbor_keys[key]) {
                neighbor_add++;
            }
            if (m[2]) {
                devices[m[2]] = true;
            }
            const hn = host_by_ll[m[1]];
            const stuck = (cost === common.STUCK_COST && lq >= common.STUCK_MIN_LQ);
            push(live, {
                hostname: hn ? hn : "",
                ipv6: m[1],
                iface: m[2],
                type: common.linkTypeLabel(m[2]),
                lq: lq,
                rxcost: int(m[4]),
                txcost: int(m[5]),
                cost: cost,
                stuck: stuck,
                tx_packets_delta: 0,
                rx_packets_delta: 0
            });
        }
        for (let k in store.last.neighbor_keys) {
            if (!new_keys[k]) {
                neighbor_remove++;
            }
        }
        store.last.neighbor_keys = new_keys;
    }

    const rn = babelDump("dump-routable-neighbors");
    if (rn) {
        for (let i = 0; i < length(rn); i++) {
            if (match(rn[i], /address /)) {
                routable_count++;
            }
        }
    }

    const routes = babelDump("dump-installed-routes");
    if (routes) {
        for (let i = 0; i < length(routes); i++) {
            const m = match(routes[i], /table ([0-9]+)/);
            if (!m) {
                continue;
            }
            const tbl = int(m[1]);
            if (tbl === 20 || tbl === 0) {
                route20++;
            }
            else if (tbl === 21) {
                route21++;
            }
            else if (tbl === 22) {
                route22++;
            }
        }
    }

    /* Device counters → aggregate TX/RX Δ (A) + per-device deltas for live/history */
    const prev_dev = store.last.link_dev || {};
    const new_dev = {};
    const prev_sta = store.last.link_sta || {};
    const new_sta = {};
    let iface_tx = 0;
    let iface_rx = 0;
    let have_prev_dev = false;
    for (let _d in prev_dev) {
        have_prev_dev = true;
        break;
    }
    for (let dev in devices) {
        const c = readDevCounters(dev);
        if (!c) {
            continue;
        }
        new_dev[dev] = c;
        iface_tx += c.tx;
        iface_rx += c.rx;
    }

    let tx_packets_delta = 0;
    let rx_packets_delta = 0;
    if (have_prev_dev) {
        for (let dev in new_dev) {
            const cur = new_dev[dev];
            const prev = prev_dev[dev];
            if (prev) {
                tx_packets_delta += max(0, cur.tx - prev.tx);
                rx_packets_delta += max(0, cur.rx - prev.rx);
            }
        }
    }
    store.last.link_dev = new_dev;
    store.last.rx_packets = iface_rx;
    store.last.tx_packets = iface_tx;

    /* Collect RF SNR + LQM retry/fail + per-link I/O candidates */
    const rf_cands = [];
    const link_cands = [];
    const link_delta_by_dev = {};
    const link_delta_by_ll = {};

    for (let dev in new_dev) {
        const cur = new_dev[dev];
        const prev = prev_dev[dev];
        let dtx = 0;
        let drx = 0;
        if (have_prev_dev && prev) {
            dtx = max(0, cur.tx - prev.tx);
            drx = max(0, cur.rx - prev.rx);
        }
        link_delta_by_dev[dev] = { tx: dtx, rx: drx };
    }

    if (lqm && lqm.trackers) {
        for (let mac in lqm.trackers) {
            const tr = lqm.trackers[mac];
            if (tr.tx_retries) {
                tx_retries += int(tr.tx_retries);
            }
            if (tr.tx_fail || tr.tx_failed) {
                tx_fail += int(tr.tx_fail || tr.tx_failed);
            }
            if (tr.type === "RF" && tr.snr != null) {
                const snr = int(tr.snr);
                snr_sum += snr;
                snr_n++;
                let label = tr.hostname;
                if (!label || label === "") {
                    label = tr.canonical_ip || mac;
                }
                push(rf_cands, { id: `${label}`, snr: snr });
            }
            if (tr.type === "RF" && tr.tx_bitrate) {
                br_sum += int(tr.tx_bitrate);
                br_n++;
            }

            let dtx = 0;
            let drx = 0;
            if (tr.type === "RF" && tr.tx_packets != null) {
                const sta_tx = int(tr.tx_packets);
                new_sta[mac] = sta_tx;
                if (prev_sta[mac] != null) {
                    dtx = max(0, sta_tx - prev_sta[mac]);
                }
                /* LQM has no per-station RX; leave rx at 0 for RF stations */
            }
            else if (tr.device && link_delta_by_dev[tr.device]) {
                dtx = link_delta_by_dev[tr.device].tx;
                drx = link_delta_by_dev[tr.device].rx;
            }
            if (tr.ipv6ll) {
                link_delta_by_ll[tr.ipv6ll] = { tx: dtx, rx: drx };
            }
            const id = linkLabelForTracker(tr, mac, tr.device);
            push(link_cands, { id: id, tx: dtx, rx: drx, score: dtx + drx, device: tr.device || "" });
        }
    }

    /* Neighbors without LQM tracker still get iface-level deltas */
    for (let i = 0; i < length(live); i++) {
        const n = live[i];
        const byll = link_delta_by_ll[n.ipv6];
        if (byll) {
            n.tx_packets_delta = byll.tx;
            n.rx_packets_delta = byll.rx;
        }
        else if (n.iface && link_delta_by_dev[n.iface]) {
            n.tx_packets_delta = link_delta_by_dev[n.iface].tx;
            n.rx_packets_delta = link_delta_by_dev[n.iface].rx;
            push(link_cands, {
                id: common.formatIfaceLabel(n.iface),
                tx: n.tx_packets_delta,
                rx: n.rx_packets_delta,
                score: n.tx_packets_delta + n.rx_packets_delta,
                device: n.iface
            });
        }
    }
    store.last.link_sta = new_sta;

    /* Sort descending SNR; cap map size for RAM */
    for (let i = 0; i < length(rf_cands); i++) {
        for (let j = i + 1; j < length(rf_cands); j++) {
            if (rf_cands[j].snr > rf_cands[i].snr) {
                const tmp = rf_cands[i];
                rf_cands[i] = rf_cands[j];
                rf_cands[j] = tmp;
            }
        }
    }
    const rf = {};
    const rf_cap = common.RF_NEIGHBOR_CAP;
    const rf_take = length(rf_cands) < rf_cap ? length(rf_cands) : rf_cap;
    for (let i = 0; i < rf_take; i++) {
        rf[rf_cands[i].id] = rf_cands[i].snr;
    }

    /* Deduplicate link candidates by id (prefer highest score), sort, cap */
    const link_best = {};
    for (let i = 0; i < length(link_cands); i++) {
        const c = link_cands[i];
        if (!c.id || c.id === "") {
            continue;
        }
        const prev = link_best[c.id];
        if (!prev || c.score > prev.score) {
            link_best[c.id] = c;
        }
    }
    const link_sorted = [];
    for (let id in link_best) {
        push(link_sorted, link_best[id]);
    }
    for (let i = 0; i < length(link_sorted); i++) {
        for (let j = i + 1; j < length(link_sorted); j++) {
            if (link_sorted[j].score > link_sorted[i].score) {
                const tmp = link_sorted[i];
                link_sorted[i] = link_sorted[j];
                link_sorted[j] = tmp;
            }
        }
    }
    const links = {};
    const link_cap = common.LINK_IO_CAP;
    const link_take = length(link_sorted) < link_cap ? length(link_sorted) : link_cap;
    for (let i = 0; i < link_take; i++) {
        const c = link_sorted[i];
        links[c.id] = [ int(c.tx), int(c.rx) ];
    }

    let tx_retries_delta = 0;
    let tx_fail_delta = 0;
    if (store.last.tx_retries !== null) {
        tx_retries_delta = max(0, tx_retries - store.last.tx_retries);
        tx_fail_delta = max(0, tx_fail - store.last.tx_fail);
    }
    store.last.tx_retries = tx_retries;
    store.last.tx_fail = tx_fail;

    const host_count = countArednlinkHosts();
    let host_change_delta = 0;
    if (store.last.host_count !== null && host_count !== store.last.host_count) {
        host_change_delta = host_count > store.last.host_count
            ? host_count - store.last.host_count
            : store.last.host_count - host_count;
    }
    store.last.host_count = host_count;

    let dns_reload_delta = 0;
    const sn = fs.stat("/tmp/dnsmasq.d/supernode.conf");
    const sd = fs.stat("/tmp/dnsmasq.d/subdomains.conf");
    let dns_mtime = 0;
    if (sn && sn.mtime) {
        dns_mtime = sn.mtime;
    }
    if (sd && sd.mtime && sd.mtime > dns_mtime) {
        dns_mtime = sd.mtime;
    }
    if (store.last.dns_mtime && dns_mtime > store.last.dns_mtime) {
        dns_reload_delta = 1;
    }
    store.last.dns_mtime = dns_mtime;

    let babel_hard_delta = 0;
    let babel_soft_delta = 0;
    const state_exists = fs.access("/etc/state/babel-state");
    const pid = babelPid();

    /* Stuck = firmware hard-reset candidate: cost 65535 + LQ >= 50 (observe only). */
    const stuck_now = {};
    let stuck_count = 0;
    let stuck_snapshot = "";
    for (let i = 0; i < length(live); i++) {
        const n = live[i];
        if (!n.stuck) {
            continue;
        }
        stuck_count++;
        const key = sprintf("%s|%s", n.ipv6, n.iface || "");
        const detail = sprintf("host=%s type=%s ipv6=%s lq=%d cost=%d",
            n.hostname !== "" ? n.hostname : "?",
            n.type || "?",
            n.ipv6,
            n.lq,
            n.cost);
        stuck_now[key] = detail;
        if (stuck_snapshot !== "") {
            stuck_snapshot += "; ";
        }
        stuck_snapshot += detail;
    }
    if (!store.last.stuck_keys) {
        store.last.stuck_keys = {};
    }
    for (let k in stuck_now) {
        if (!store.last.stuck_keys[k]) {
            storelib.pushEvent(store, "babel_stuck", stuck_now[k]);
        }
    }
    for (let k in store.last.stuck_keys) {
        if (!stuck_now[k]) {
            storelib.pushEvent(store, "babel_unstuck", store.last.stuck_keys[k]);
        }
    }

    if (store.last.babel_state_seen === true && !state_exists) {
        babel_hard_delta = 1;
        let hard_detail = "babel-state removed";
        const prior = store.last.stuck_snapshot || "";
        if (prior !== "") {
            hard_detail = sprintf("babel-state removed; prior_stuck=[%s]", prior);
        }
        else if (stuck_snapshot !== "") {
            hard_detail = sprintf("babel-state removed; stuck=[%s]", stuck_snapshot);
        }
        storelib.pushEvent(store, "babel_hard", hard_detail);
    }
    if (store.last.babel_pid && pid && store.last.babel_pid !== pid && state_exists) {
        babel_soft_delta = 1;
        storelib.pushEvent(store, "babel_soft", sprintf("babeld pid %d -> %d", store.last.babel_pid, pid));
    }
    if (neighbor_add || neighbor_remove) {
        storelib.pushEvent(store, "neighbor_churn",
            sprintf("add=%d remove=%d", neighbor_add, neighbor_remove));
    }
    store.last.babel_state_seen = state_exists ? true : false;
    store.last.babel_pid = pid;
    store.last.stuck_keys = stuck_now;
    store.last.stuck_snapshot = stuck_snapshot;

    /* Live API: publish type + stuck, drop iface (not kept in the sample ring either) */
    const live_pub = [];
    for (let i = 0; i < length(live); i++) {
        const n = live[i];
        push(live_pub, {
            hostname: n.hostname,
            ipv6: n.ipv6,
            type: n.type || common.linkTypeLabel(n.iface),
            lq: n.lq,
            rxcost: n.rxcost,
            txcost: n.txcost,
            cost: n.cost,
            stuck: n.stuck ? true : false,
            tx_packets_delta: n.tx_packets_delta,
            rx_packets_delta: n.rx_packets_delta
        });
    }
    store.live_neighbors = live_pub;

    store.wg = readWgTunnelStats();

    const mean_lq = neighbor_count ? int(lq_sum / neighbor_count) : 0;
    const mean_cost = cost_n ? int(cost_sum / cost_n) : 0;

    /* Host health: uptime (reboot detect), RAM, CPU interval + peak */
    const uptime_s = readUptimeS();
    let reboot_delta = 0;
    if (store.last.uptime_s !== null && uptime_s < store.last.uptime_s) {
        reboot_delta = 1;
        storelib.pushEvent(store, "reboot",
            sprintf("uptime %d -> %d", store.last.uptime_s, uptime_s));
    }
    store.last.uptime_s = uptime_s;

    const mem = readMemInfo();
    store.last.mem_total_kb = mem.total_kb;
    const cpu_cur = readCpuStat();
    let cpu_pct = 0;
    if (cpu_cur) {
        if (store.last.cpu_total !== null) {
            cpu_pct = cpuPctFromDelta(
                { total: store.last.cpu_total, idle: store.last.cpu_idle },
                cpu_cur
            );
        }
        store.last.cpu_total = cpu_cur.total;
        store.last.cpu_idle = cpu_cur.idle;
    }
    let cpu_peak_pct = store.last.cpu_peak_pct || 0;
    if (cpu_pct > cpu_peak_pct) {
        cpu_peak_pct = cpu_pct;
    }
    /* reset peak window for next interval */
    store.last.cpu_peak_pct = 0;
    store.last.cpu_peak_total = cpu_cur ? cpu_cur.total : null;
    store.last.cpu_peak_idle = cpu_cur ? cpu_cur.idle : null;

    const sample = {
        t: t,
        seq: 0,
        neighbor_count: neighbor_count,
        routable_count: routable_count,
        route_count_20: route20,
        route_count_21: route21,
        route_count_22: route22,
        mean_lq: mean_lq,
        min_lq: neighbor_count ? lq_min : 0,
        mean_cost: mean_cost,
        bad_cost_count: bad_cost,
        stuck_neighbor_count: stuck_count,
        neighbor_add: neighbor_add,
        neighbor_remove: neighbor_remove,
        tx_packets_delta: tx_packets_delta,
        tx_retries_delta: tx_retries_delta,
        tx_fail_delta: tx_fail_delta,
        mean_snr: snr_n ? int(snr_sum / snr_n) : 0,
        mean_tx_bitrate: br_n ? int(br_sum / br_n) : 0,
        host_count: host_count,
        host_change_delta: host_change_delta,
        dns_reload_delta: dns_reload_delta,
        babel_hard_delta: babel_hard_delta,
        babel_soft_delta: babel_soft_delta,
        uptime_s: uptime_s,
        reboot_delta: reboot_delta,
        mem_available_kb: mem.available_kb,
        mem_used_pct: mem.used_pct,
        cpu_pct: cpu_pct,
        cpu_peak_pct: cpu_peak_pct,
        lqm_ok: lqm_ok ? 1 : 0,
        babel_ok: babel_ok ? 1 : 0,
        rx_packets_delta: rx_packets_delta,
        daemon_rss_kb: readDaemonRssKb()
    };
    /* Only attach rf/links maps when non-empty (avoids 1440 empty objects) */
    let rf_n = 0;
    for (let _k in rf) {
        rf_n++;
        break;
    }
    if (rf_n) {
        sample.rf = rf;
    }
    let links_n = 0;
    for (let _k in links) {
        links_n++;
        break;
    }
    if (links_n) {
        sample.links = links;
    }

    /* Per-neighbor Babel cost history (hostname when known; capped). */
    const cost_cands = [];
    for (let i = 0; i < length(live); i++) {
        const n = live[i];
        const id = (n.hostname && n.hostname !== "") ? n.hostname : n.ipv6;
        if (!id || id === "") {
            continue;
        }
        push(cost_cands, { id: id, cost: int(n.cost), score: int(n.cost) });
    }
    for (let i = 0; i < length(cost_cands); i++) {
        for (let j = i + 1; j < length(cost_cands); j++) {
            if (cost_cands[j].score > cost_cands[i].score) {
                const tmp = cost_cands[i];
                cost_cands[i] = cost_cands[j];
                cost_cands[j] = tmp;
            }
        }
    }
    const costs = {};
    const cost_cap = common.COST_NEIGHBOR_CAP;
    const cost_take = length(cost_cands) < cost_cap ? length(cost_cands) : cost_cap;
    for (let i = 0; i < cost_take; i++) {
        costs[cost_cands[i].id] = cost_cands[i].cost;
    }
    let costs_n = 0;
    for (let _k in costs) {
        costs_n++;
        break;
    }
    if (costs_n) {
        sample.costs = costs;
    }

    if (cfg.enabled) {
        storelib.pushSample(store, sample);
    }

    return sample;
};

/** Public babel.sock dump helper for Logs → Dumps UI. */
export function babelDumpCmd(cmd)
{
    return babelDump(cmd);
};
