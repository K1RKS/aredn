/**
 * In-RAM packed sample + event rings (no flash I/O).
 *
 * Samples are stored as dense arrays (not keyed objects) to cut ucode RAM.
 * Wire/API responses expand back to named fields via expandSample().
 *
 * Packed layout (schema 4):
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
 *  31 rf (null or {label: snr, ...} when non-empty)
 */
import * as common from "babel_monitor.common";

export function createStore()
{
    const samples = [];
    const events = [];
    for (let i = 0; i < common.SAMPLE_CAP; i++) {
        push(samples, null);
    }
    for (let i = 0; i < common.EVENT_CAP; i++) {
        push(events, null);
    }

    return {
        samples,
        events,
        sample_cap: common.SAMPLE_CAP,
        event_cap: common.EVENT_CAP,
        sample_head: 0,
        sample_count: 0,
        event_head: 0,
        event_count: 0,
        next_seq: 1,
        next_event_seq: 1,
        boot_id: null,
        last: {
            tx_packets: null,
            tx_retries: null,
            tx_fail: null,
            host_count: null,
            babel_state_seen: null,
            babel_pid: null,
            dns_mtime: null,
            neighbor_keys: {},
            uptime_s: null,
            cpu_total: null,
            cpu_idle: null,
            cpu_peak_total: null,
            cpu_peak_idle: null,
            cpu_peak_pct: 0,
            mem_total_kb: null
        },
        live_neighbors: [],
        identity: {
            node_id: "",
            mac: "",
            hostname: ""
        }
    };
};

function rfNonEmpty(rf)
{
    if (rf == null) {
        return null;
    }
    for (let k in rf) {
        return rf;
    }
    return null;
};

/** Pack a named sample object into a dense array for the ring. */
export function packSample(s)
{
    return [
        int(s.t), int(s.seq),
        int(s.neighbor_count), int(s.routable_count),
        int(s.route_count_20), int(s.route_count_21), int(s.route_count_22),
        int(s.mean_lq), int(s.min_lq), int(s.mean_cost), int(s.bad_cost_count),
        int(s.neighbor_add), int(s.neighbor_remove),
        int(s.tx_packets_delta), int(s.tx_retries_delta), int(s.tx_fail_delta),
        int(s.mean_snr), int(s.mean_tx_bitrate),
        int(s.host_count), int(s.host_change_delta),
        int(s.dns_reload_delta), int(s.babel_hard_delta), int(s.babel_soft_delta),
        int(s.uptime_s), int(s.reboot_delta),
        int(s.mem_used_pct), int(s.mem_available_kb),
        int(s.cpu_pct), int(s.cpu_peak_pct),
        int(s.lqm_ok), int(s.babel_ok),
        rfNonEmpty(s.rf)
    ];
};

/** Expand a packed ring entry (or pass through a legacy object). */
export function expandSample(p)
{
    if (p == null) {
        return null;
    }
    if (type(p) != "array") {
        return p;
    }
    const o = {
        t: p[0],
        seq: p[1],
        neighbor_count: p[2],
        routable_count: p[3],
        route_count_20: p[4],
        route_count_21: p[5],
        route_count_22: p[6],
        mean_lq: p[7],
        min_lq: p[8],
        mean_cost: p[9],
        bad_cost_count: p[10],
        neighbor_add: p[11],
        neighbor_remove: p[12],
        tx_packets_delta: p[13],
        tx_retries_delta: p[14],
        tx_fail_delta: p[15],
        mean_snr: p[16],
        mean_tx_bitrate: p[17],
        host_count: p[18],
        host_change_delta: p[19],
        dns_reload_delta: p[20],
        babel_hard_delta: p[21],
        babel_soft_delta: p[22],
        uptime_s: p[23],
        reboot_delta: p[24],
        mem_used_pct: p[25],
        mem_available_kb: p[26],
        cpu_pct: p[27],
        cpu_peak_pct: p[28],
        lqm_ok: p[29],
        babel_ok: p[30]
    };
    if (p[31] != null) {
        o.rf = p[31];
    }
    return o;
};

function packedT(p)
{
    if (p == null) {
        return 0;
    }
    if (type(p) == "array") {
        return p[0];
    }
    return p.t;
};

function packedSeq(p)
{
    if (p == null) {
        return 0;
    }
    if (type(p) == "array") {
        return p[1];
    }
    return p.seq;
};

export function pushSample(store, s)
{
    s.seq = store.next_seq;
    store.next_seq++;
    store.samples[store.sample_head] = packSample(s);
    store.sample_head = (store.sample_head + 1) % store.sample_cap;
    if (store.sample_count < store.sample_cap) {
        store.sample_count++;
    }
};

export function pushEvent(store, type, detail)
{
    const e = {
        t: common.nowUnix(),
        seq: store.next_event_seq,
        type: type,
        detail: detail || ""
    };
    store.next_event_seq++;
    store.events[store.event_head] = e;
    store.event_head = (store.event_head + 1) % store.event_cap;
    if (store.event_count < store.event_cap) {
        store.event_count++;
    }
};

/** Oldest-first list of samples with seq > since_seq, max limit (expanded). */
export function syncSamples(store, since_seq, limit)
{
    const out = [];
    const n = store.sample_count;
    if (n === 0) {
        return { samples: out, truncated: since_seq > 0, oldest_seq: 0, newest_seq: 0 };
    }

    const start = (store.sample_head - n + store.sample_cap) % store.sample_cap;
    let oldest_seq = 0;
    let newest_seq = 0;
    for (let i = 0; i < n; i++) {
        const raw = store.samples[(start + i) % store.sample_cap];
        if (!raw) {
            continue;
        }
        const seq = packedSeq(raw);
        if (oldest_seq === 0) {
            oldest_seq = seq;
        }
        newest_seq = seq;
        if (seq > since_seq) {
            if (length(out) < limit) {
                push(out, expandSample(raw));
            }
        }
    }
    const truncated = since_seq > 0 && since_seq < oldest_seq - 1;
    return {
        samples: out,
        truncated: truncated,
        oldest_seq: oldest_seq,
        newest_seq: newest_seq,
        gap_before: truncated ? { t: null, seq: oldest_seq } : null
    };
};

export function syncEvents(store, since_seq, limit)
{
    const out = [];
    const n = store.event_count;
    if (n === 0) {
        return { events: out, truncated: false, oldest_seq: 0, newest_seq: 0 };
    }

    const start = (store.event_head - n + store.event_cap) % store.event_cap;
    let oldest_seq = 0;
    let newest_seq = 0;
    for (let i = 0; i < n; i++) {
        const e = store.events[(start + i) % store.event_cap];
        if (!e) {
            continue;
        }
        if (oldest_seq === 0) {
            oldest_seq = e.seq;
        }
        newest_seq = e.seq;
        if (e.seq > since_seq && length(out) < limit) {
            push(out, e);
        }
    }
    return {
        events: out,
        truncated: since_seq > 0 && since_seq < oldest_seq - 1,
        oldest_seq: oldest_seq,
        newest_seq: newest_seq
    };
};

export function seriesWindow(store, seconds)
{
    const out = [];
    const n = store.sample_count;
    if (n === 0) {
        return out;
    }
    const cutoff = common.nowUnix() - seconds;
    const start = (store.sample_head - n + store.sample_cap) % store.sample_cap;
    for (let i = 0; i < n; i++) {
        const raw = store.samples[(start + i) % store.sample_cap];
        if (raw && packedT(raw) >= cutoff) {
            push(out, expandSample(raw));
        }
    }
    return out;
};

export function latestSample(store)
{
    if (store.sample_count < 1) {
        return null;
    }
    return expandSample(store.samples[(store.sample_head - 1 + store.sample_cap) % store.sample_cap]);
};

export function oldestSample(store)
{
    if (store.sample_count < 1) {
        return null;
    }
    return expandSample(store.samples[(store.sample_head - store.sample_count + store.sample_cap) % store.sample_cap]);
};

export function estimateBytes(store)
{
    /* Packed arrays ~40 ints + optional rf map; ucode still has overhead */
    return 98304 + store.sample_count * 350 + store.event_count * 64;
};
