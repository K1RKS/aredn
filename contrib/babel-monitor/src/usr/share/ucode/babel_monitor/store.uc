/**
 * In-RAM packed sample + event rings (no flash I/O).
 * Samples stored as fixed-key objects in a preallocated circular buffer.
 */
import * as common from "babel_monitor.common";

export function createStore()
{
    const samples = [];
    const events = [];
    /* Pre-size arrays to avoid realloc growth */
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
            cpu_peak_pct: 0
        },
        live_neighbors: [],
        identity: {
            node_id: "",
            mac: "",
            hostname: ""
        }
    };
};

export function pushSample(store, s)
{
    s.seq = store.next_seq;
    store.next_seq++;
    store.samples[store.sample_head] = s;
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

/** Oldest-first list of samples with seq > since_seq, max limit */
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
        const s = store.samples[(start + i) % store.sample_cap];
        if (!s) {
            continue;
        }
        if (oldest_seq === 0) {
            oldest_seq = s.seq;
        }
        newest_seq = s.seq;
        if (s.seq > since_seq) {
            if (length(out) < limit) {
                push(out, s);
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
        const s = store.samples[(start + i) % store.sample_cap];
        if (s && s.t >= cutoff) {
            push(out, s);
        }
    }
    return out;
};

export function estimateBytes(store)
{
    /* Rough: ~100 bytes/sample + ~48 bytes/event + overhead */
    return store.sample_count * 100 + store.event_count * 48 + 65536;
};
