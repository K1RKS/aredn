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
    for (;;) {
        const v = c.recv();
        if (!v || v === "") {
            break;
        }
        d += v;
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

    let tx_packets = 0;
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
            push(live, {
                ipv6: m[1],
                iface: m[2],
                lq: lq,
                rxcost: int(m[4]),
                txcost: int(m[5]),
                cost: cost
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

    const lqm = readJsonFile("/tmp/lqm.info");
    if (lqm && lqm.trackers) {
        lqm_ok = true;
        for (let mac in lqm.trackers) {
            const tr = lqm.trackers[mac];
            if (tr.tx_packets) {
                tx_packets += int(tr.tx_packets);
            }
            if (tr.tx_retries) {
                tx_retries += int(tr.tx_retries);
            }
            if (tr.tx_fail || tr.tx_failed) {
                tx_fail += int(tr.tx_fail || tr.tx_failed);
            }
            if (tr.snr !== null && tr.snr !== undefined) {
                snr_sum += int(tr.snr);
                snr_n++;
            }
            if (tr.tx_bitrate) {
                br_sum += int(tr.tx_bitrate);
                br_n++;
            }
        }
    }

    let tx_packets_delta = 0;
    let tx_retries_delta = 0;
    let tx_fail_delta = 0;
    if (store.last.tx_packets !== null) {
        tx_packets_delta = max(0, tx_packets - store.last.tx_packets);
        tx_retries_delta = max(0, tx_retries - store.last.tx_retries);
        tx_fail_delta = max(0, tx_fail - store.last.tx_fail);
    }
    store.last.tx_packets = tx_packets;
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
    if (store.last.babel_state_seen === true && !state_exists) {
        babel_hard_delta = 1;
        storelib.pushEvent(store, "babel_hard", "babel-state removed");
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

    store.live_neighbors = live;

    const mean_lq = neighbor_count ? int(lq_sum / neighbor_count) : 0;
    const mean_cost = cost_n ? int(cost_sum / cost_n) : 0;

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
        lqm_ok: lqm_ok ? 1 : 0,
        babel_ok: babel_ok ? 1 : 0
    };

    if (cfg.enabled) {
        storelib.pushSample(store, sample);
    }

    return sample;
};
