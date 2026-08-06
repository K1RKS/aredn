/**
 * In-RAM dense sample + event rings (no flash I/O).
 *
 * Samples live in one statically allocated flat int buffer:
 *   index i → offset i * SAMPLE_WIDTH (schema 9).
 * A rolling sample_head overwrites slots in place — never allocate/drop sample
 * vectors. RF/link/cost labels live once in store.labels; the buffer stores indices.
 * Wire/API expands to named fields on demand (never cached on the store).
 */
import * as common from "babel_monitor.common";

function newEventSlot()
{
    return { t: 0, seq: 0, type: "", detail: "" };
}

export function createStore(sample_cap)
{
    if (sample_cap == null) {
        sample_cap = common.SAMPLE_CAP;
    }
    sample_cap = int(sample_cap);
    if (sample_cap < 0) {
        sample_cap = 0;
    }
    if (sample_cap > common.SAMPLE_CAP_MAX) {
        sample_cap = common.SAMPLE_CAP_MAX;
    }
    const buf = [];
    const n = sample_cap * common.SAMPLE_WIDTH;
    for (let i = 0; i < n; i++) {
        push(buf, 0);
    }
    const events = [];
    for (let i = 0; i < common.EVENT_CAP; i++) {
        push(events, newEventSlot());
    }

    return {
        buf,
        events,
        labels: [],
        label_by_name: {},
        sample_cap: sample_cap,
        event_cap: common.EVENT_CAP,
        sample_head: 0,
        sample_count: 0,
        event_head: 0,
        event_count: 0,
        next_seq: 1,
        next_event_seq: 1,
        boot_id: null,
        latest_obj: null,
        last: {
            tx_packets: null,
            tx_retries: null,
            tx_fail: null,
            rx_packets: null,
            link_dev: {},
            link_sta: {},
            host_count: null,
            babel_state_seen: null,
            babel_pid: null,
            dns_mtime: null,
            neighbor_keys: {},
            stuck_keys: {},
            stuck_snapshot: "",
            uptime_s: null,
            cpu_total: null,
            cpu_idle: null,
            cpu_peak_total: null,
            cpu_peak_idle: null,
            cpu_peak_pct: 0,
            mem_total_kb: null
        },
        live_neighbors: [],
        wg: {
            server_tunnels: { live: 0, active: 0, total: 0 },
            clients: { live: 0, active: 0, total: 0 }
        },
        identity: {
            node_id: "",
            mac: "",
            hostname: ""
        }
    };
};

/** Rebuild sample buffer to a new capacity; clears sample history. */
export function resizeSampleRing(store, sample_cap)
{
    sample_cap = int(sample_cap);
    if (sample_cap < 0) {
        sample_cap = 0;
    }
    if (sample_cap > common.SAMPLE_CAP_MAX) {
        sample_cap = common.SAMPLE_CAP_MAX;
    }
    const buf = [];
    const n = sample_cap * common.SAMPLE_WIDTH;
    for (let i = 0; i < n; i++) {
        push(buf, 0);
    }
    store.buf = buf;
    store.sample_cap = sample_cap;
    store.sample_head = 0;
    store.sample_count = 0;
    store.latest_obj = null;
    return store.sample_cap;
};

function slotOff(i)
{
    return i * common.SAMPLE_WIDTH;
};

/** Intern a display label; returns index or -1 if dictionary is full. */
export function internLabel(store, name)
{
    if (name == null || name === "") {
        return -1;
    }
    const key = `${name}`;
    const existing = store.label_by_name[key];
    if (existing != null) {
        return int(existing);
    }
    if (length(store.labels) >= common.LABEL_CAP) {
        return -1;
    }
    const idx = length(store.labels);
    push(store.labels, key);
    store.label_by_name[key] = idx;
    return idx;
};

function labelAt(store, idx)
{
    if (idx == null || idx < 0) {
        return "";
    }
    const n = length(store.labels);
    if (idx >= n) {
        return "";
    }
    return store.labels[idx];
};

function packedTAt(store, slot)
{
    return int(store.buf[slotOff(slot)]);
};

function packedSeqAt(store, slot)
{
    return int(store.buf[slotOff(slot) + 1]);
};

/**
 * Write sample fields into flat buffer slot (in place).
 * Optional s.rf / s.links maps become label-index pairs/triples.
 */
export function writeSampleSlot(store, slot, s)
{
    const b = store.buf;
    const o = slotOff(slot);
    b[o + 0] = int(s.t);
    b[o + 1] = int(s.seq);
    b[o + 2] = int(s.neighbor_count);
    b[o + 3] = int(s.routable_count);
    b[o + 4] = int(s.route_count_20);
    b[o + 5] = int(s.route_count_21);
    b[o + 6] = int(s.route_count_22);
    b[o + 7] = int(s.mean_lq);
    b[o + 8] = int(s.min_lq);
    b[o + 9] = int(s.mean_cost);
    b[o + 10] = int(s.bad_cost_count);
    b[o + 11] = int(s.neighbor_add);
    b[o + 12] = int(s.neighbor_remove);
    b[o + 13] = int(s.tx_packets_delta);
    b[o + 14] = int(s.tx_retries_delta);
    b[o + 15] = int(s.tx_fail_delta);
    b[o + 16] = int(s.mean_snr);
    b[o + 17] = int(s.mean_tx_bitrate);
    b[o + 18] = int(s.host_count);
    b[o + 19] = int(s.host_change_delta);
    b[o + 20] = int(s.dns_reload_delta);
    b[o + 21] = int(s.babel_hard_delta);
    b[o + 22] = int(s.babel_soft_delta);
    b[o + 23] = int(s.uptime_s);
    b[o + 24] = int(s.reboot_delta);
    b[o + 25] = int(s.mem_used_pct);
    b[o + 26] = int(s.mem_available_kb);
    b[o + 27] = int(s.cpu_pct);
    b[o + 28] = int(s.cpu_peak_pct);
    b[o + 29] = int(s.lqm_ok);
    b[o + 30] = int(s.babel_ok);
    b[o + 31] = int(s.rx_packets_delta);
    b[o + 32] = s.daemon_rss_kb != null ? int(s.daemon_rss_kb) : 0;
    b[o + 35] = int(s.stuck_neighbor_count);

    let rf_n = 0;
    const rf_base = o + common.SAMPLE_HDR;
    if (s.rf) {
        for (let name in s.rf) {
            if (rf_n >= common.RF_NEIGHBOR_CAP) {
                break;
            }
            const li = internLabel(store, name);
            if (li < 0) {
                continue;
            }
            b[rf_base + rf_n * 2] = li;
            b[rf_base + rf_n * 2 + 1] = int(s.rf[name]);
            rf_n++;
        }
    }
    b[o + 33] = rf_n;
    for (let i = rf_n; i < common.RF_NEIGHBOR_CAP; i++) {
        b[rf_base + i * 2] = 0;
        b[rf_base + i * 2 + 1] = 0;
    }

    let link_n = 0;
    const link_base = o + common.SAMPLE_HDR + common.RF_NEIGHBOR_CAP * 2;
    if (s.links) {
        for (let name in s.links) {
            if (link_n >= common.LINK_IO_CAP) {
                break;
            }
            const li = internLabel(store, name);
            if (li < 0) {
                continue;
            }
            const pair = s.links[name];
            let tx = 0;
            let rx = 0;
            if (type(pair) == "array") {
                tx = int(pair[0]);
                rx = int(pair[1]);
            }
            else if (pair) {
                tx = int(pair.tx);
                rx = int(pair.rx);
            }
            b[link_base + link_n * 3] = li;
            b[link_base + link_n * 3 + 1] = tx;
            b[link_base + link_n * 3 + 2] = rx;
            link_n++;
        }
    }
    b[o + 34] = link_n;
    for (let i = link_n; i < common.LINK_IO_CAP; i++) {
        b[link_base + i * 3] = 0;
        b[link_base + i * 3 + 1] = 0;
        b[link_base + i * 3 + 2] = 0;
    }

    let cost_n = 0;
    const cost_base = o + common.SAMPLE_HDR
        + common.RF_NEIGHBOR_CAP * 2
        + common.LINK_IO_CAP * 3;
    if (s.costs) {
        for (let name in s.costs) {
            if (cost_n >= common.COST_NEIGHBOR_CAP) {
                break;
            }
            const li = internLabel(store, name);
            if (li < 0) {
                continue;
            }
            b[cost_base + cost_n * 2] = li;
            b[cost_base + cost_n * 2 + 1] = int(s.costs[name]);
            cost_n++;
        }
    }
    b[o + 36] = cost_n;
    for (let i = cost_n; i < common.COST_NEIGHBOR_CAP; i++) {
        b[cost_base + i * 2] = 0;
        b[cost_base + i * 2 + 1] = 0;
    }
};

/** Expand one ring slot to named wire fields (ephemeral). */
export function expandSampleAt(store, slot)
{
    const b = store.buf;
    const o = slotOff(slot);
    const obj = {
        t: b[o + 0],
        seq: b[o + 1],
        neighbor_count: b[o + 2],
        routable_count: b[o + 3],
        route_count_20: b[o + 4],
        route_count_21: b[o + 5],
        route_count_22: b[o + 6],
        mean_lq: b[o + 7],
        min_lq: b[o + 8],
        mean_cost: b[o + 9],
        bad_cost_count: b[o + 10],
        neighbor_add: b[o + 11],
        neighbor_remove: b[o + 12],
        tx_packets_delta: b[o + 13],
        tx_retries_delta: b[o + 14],
        tx_fail_delta: b[o + 15],
        mean_snr: b[o + 16],
        mean_tx_bitrate: b[o + 17],
        host_count: b[o + 18],
        host_change_delta: b[o + 19],
        dns_reload_delta: b[o + 20],
        babel_hard_delta: b[o + 21],
        babel_soft_delta: b[o + 22],
        uptime_s: b[o + 23],
        reboot_delta: b[o + 24],
        mem_used_pct: b[o + 25],
        mem_available_kb: b[o + 26],
        cpu_pct: b[o + 27],
        cpu_peak_pct: b[o + 28],
        lqm_ok: b[o + 29],
        babel_ok: b[o + 30],
        rx_packets_delta: b[o + 31],
        daemon_rss_kb: b[o + 32],
        stuck_neighbor_count: b[o + 35]
    };

    const rf_n = int(b[o + 33] || 0);
    if (rf_n > 0) {
        const rf = {};
        const rf_base = o + common.SAMPLE_HDR;
        for (let i = 0; i < rf_n && i < common.RF_NEIGHBOR_CAP; i++) {
            const name = labelAt(store, b[rf_base + i * 2]);
            if (name !== "") {
                rf[name] = b[rf_base + i * 2 + 1];
            }
        }
        obj.rf = rf;
    }

    const link_n = int(b[o + 34] || 0);
    if (link_n > 0) {
        const links = {};
        const link_base = o + common.SAMPLE_HDR + common.RF_NEIGHBOR_CAP * 2;
        for (let i = 0; i < link_n && i < common.LINK_IO_CAP; i++) {
            const name = labelAt(store, b[link_base + i * 3]);
            if (name !== "") {
                links[name] = [ int(b[link_base + i * 3 + 1]), int(b[link_base + i * 3 + 2]) ];
            }
        }
        obj.links = links;
    }

    const cost_n = int(b[o + 36] || 0);
    if (cost_n > 0) {
        const costs = {};
        const cost_base = o + common.SAMPLE_HDR
            + common.RF_NEIGHBOR_CAP * 2
            + common.LINK_IO_CAP * 3;
        for (let i = 0; i < cost_n && i < common.COST_NEIGHBOR_CAP; i++) {
            const name = labelAt(store, b[cost_base + i * 2]);
            if (name !== "") {
                costs[name] = b[cost_base + i * 2 + 1];
            }
        }
        obj.costs = costs;
    }

    return obj;
};

export function pushSample(store, s)
{
    s.seq = store.next_seq;
    store.next_seq++;
    /* Keep a named latest for live KPIs even when ring_size=none */
    store.latest_obj = s;
    if (store.sample_cap < 1) {
        return;
    }
    writeSampleSlot(store, store.sample_head, s);
    store.sample_head = (store.sample_head + 1) % store.sample_cap;
    if (store.sample_count < store.sample_cap) {
        store.sample_count++;
    }
};

export function pushEvent(store, type, detail)
{
    const e = store.events[store.event_head];
    e.t = common.nowUnix();
    e.seq = store.next_event_seq;
    e.type = type || "";
    e.detail = detail || "";
    store.next_event_seq++;
    store.event_head = (store.event_head + 1) % store.event_cap;
    if (store.event_count < store.event_cap) {
        store.event_count++;
    }
};

export function peekOldest(store)
{
    if (store.sample_count < 1) {
        return null;
    }
    const slot = (store.sample_head - store.sample_count + store.sample_cap) % store.sample_cap;
    return { t: packedTAt(store, slot), seq: packedSeqAt(store, slot) };
};

export function peekNewest(store)
{
    if (store.sample_count < 1) {
        return null;
    }
    const slot = (store.sample_head - 1 + store.sample_cap) % store.sample_cap;
    return { t: packedTAt(store, slot), seq: packedSeqAt(store, slot) };
};

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
        const slot = (start + i) % store.sample_cap;
        const seq = packedSeqAt(store, slot);
        if (oldest_seq === 0) {
            oldest_seq = seq;
        }
        newest_seq = seq;
        if (seq > since_seq && length(out) < limit) {
            push(out, expandSampleAt(store, slot));
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
        if (oldest_seq === 0) {
            oldest_seq = e.seq;
        }
        newest_seq = e.seq;
        if (e.seq > since_seq && length(out) < limit) {
            push(out, {
                t: e.t,
                seq: e.seq,
                type: e.type,
                detail: e.detail
            });
        }
    }
    return {
        events: out,
        truncated: since_seq > 0 && since_seq < oldest_seq - 1,
        oldest_seq: oldest_seq,
        newest_seq: newest_seq
    };
};

/**
 * Expand samples in [now - end_age - seconds, now - end_age].
 * seconds capped to SERIES_SLICE_S (5m) so one request cannot expand the full ring.
 */
export function seriesWindow(store, seconds, end_age)
{
    const out = [];
    const n = store.sample_count;
    if (n === 0) {
        return out;
    }
    const sec = common.clampInt(seconds, 1, common.SERIES_SLICE_S, common.SERIES_SLICE_S);
    const age = common.clampInt(end_age || 0, 0, common.SERIES_END_AGE_MAX, 0);
    const now = common.nowUnix();
    const win_end = now - age;
    const win_start = win_end - sec;
    const start = (store.sample_head - n + store.sample_cap) % store.sample_cap;
    for (let i = 0; i < n; i++) {
        const slot = (start + i) % store.sample_cap;
        const t = packedTAt(store, slot);
        if (t >= win_start && t <= win_end) {
            push(out, expandSampleAt(store, slot));
        }
    }
    return out;
};

export function latestSample(store)
{
    if (store.sample_cap < 1) {
        return store.latest_obj;
    }
    if (store.sample_count < 1) {
        return store.latest_obj;
    }
    return expandSampleAt(store, (store.sample_head - 1 + store.sample_cap) % store.sample_cap);
};

export function oldestSample(store)
{
    if (store.sample_count < 1) {
        return null;
    }
    return expandSampleAt(store, (store.sample_head - store.sample_count + store.sample_cap) % store.sample_cap);
};

export function estimateBytes(store)
{
    let label_bytes = 0;
    for (let i = 0; i < length(store.labels); i++) {
        label_bytes += 24 + length(store.labels[i]);
    }
    /* One flat buf + event shells + labels */
    return 49152
        + length(store.buf) * common.INT_ESTIMATE_BYTES
        + store.event_cap * 96
        + label_bytes;
};
