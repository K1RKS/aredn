/*
 * AREDN terminal session helpers: authV1, ash session I/O, apps-bar badges.
 * One shell, multiple browser clients (one primary writer + readonly viewers).
 */

import * as fs from "fs";
import * as configuration from "aredn.configuration";

export const SESSION_ROOT = "/tmp/aredn-terminal";
export const SHELL_DIR = "/tmp/aredn-terminal/active";
export const CLIENTS_DIR = "/tmp/aredn-terminal/active/clients";
export const BADGE_DIR = "/tmp/apps/terminal";
export const IDLE_SECS = 60;
export const AUTH_AGE = 315360000; // 10 years (match stock UI)
export const VIEWER_CATCHUP = 32768; // bytes of history for new viewers

const DAYS = [ "", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" ];
const MONTHS = [ "", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" ];

let shadowKey = null;

export function initKey()
{
    if (!shadowKey) {
        const f = fs.open("/etc/shadow");
        if (f) {
            for (let l = f.read("line"); length(l); l = f.read("line")) {
                if (index(l, "root:") === 0) {
                    shadowKey = trim(l);
                    break;
                }
            }
            f.close();
        }
    }
    return shadowKey;
};

export function getCookieHeader()
{
    initKey();
    if (!shadowKey) {
        return null;
    }
    const time = clock();
    const gm = gmtime(time[0] + AUTH_AGE);
    const tm = `${DAYS[gm.wday]}, ${gm.mday} ${MONTHS[gm.mon]} ${gm.year} 00:00:00 GMT`;
    return `authV1=${b64enc(shadowKey)}; Path=/; Expires=${tm}; SameSite=Lax`;
};

export function clearCookieHeader()
{
    return `authV1=; Path=/; Max-Age=0;`;
};

export function cookieValue(env)
{
    const cookieheader = env.HTTP_COOKIE || "";
    if (!cookieheader) {
        return null;
    }
    const ca = split(cookieheader, ";");
    for (let i = 0; i < length(ca); i++) {
        const cookie = trim(ca[i]);
        if (index(cookie, "authV1=") === 0) {
            return substr(cookie, 7);
        }
    }
    return null;
};

export function isAuthenticated(env)
{
    initKey();
    if (!shadowKey) {
        return false;
    }
    const v = cookieValue(env);
    if (!v) {
        return false;
    }
    return shadowKey == b64dec(v);
};

export function authenticatePassword(password)
{
    initKey();
    if (!shadowKey) {
        return false;
    }
    const s = split(shadowKey, /[:$]/);
    const f = fs.popen(`exec /usr/bin/mkpasswd -m md5 -S '${s[3]}' ${configuration.shellEscape(replace(password, /[#'"]/g, ""))}`);
    if (!f) {
        return false;
    }
    const pwd = rtrim(f.read("all"));
    f.close();
    return index(shadowKey, `root:${pwd}:`) === 0;
};

export function ensureDir(path)
{
    if (!fs.stat(path)) {
        system(`mkdir -p '${path}'`);
    }
};

export function setBadge(busy)
{
    ensureDir(BADGE_DIR);
    if (busy) {
        fs.writefile(`${BADGE_DIR}/badge`, "BUSY");
        fs.writefile(`${BADGE_DIR}/badge-color`, "#c44c44");
    }
    else {
        system(`rm -f '${BADGE_DIR}/badge' '${BADGE_DIR}/badge-color'`);
    }
};

export function clearBadge()
{
    setBadge(false);
};

function shellAlive()
{
    const pid = trim(fs.readfile(`${SHELL_DIR}/pid`) || "");
    if (!pid || !match(pid, /^[0-9]+$/)) {
        return false;
    }
    return system(`kill -0 ${pid} 2>/dev/null`) === 0;
};

function newId()
{
    const t = clock();
    return sprintf("%08x%04x", t[0] & 0xffffffff, t[1] & 0xffff);
};

function clientDir(cid)
{
    return `${CLIENTS_DIR}/${cid}`;
};

function validId(id)
{
    return id && !match(id, /[^0-9a-f]/);
};

function readRole(cid)
{
    return trim(fs.readfile(`${clientDir(cid)}/role`) || "");
};

function writeRole(cid, role)
{
    fs.writefile(`${clientDir(cid)}/role`, role);
};

function touchClient(cid)
{
    fs.writefile(`${clientDir(cid)}/heartbeat`, `${clock()[0]}`);
};

function listClientIds()
{
    const out = [];
    const entries = fs.lsdir(CLIENTS_DIR);
    if (!entries) {
        return out;
    }
    for (let i = 0; i < length(entries); i++) {
        const name = entries[i];
        if (substr(name, 0, 1) !== "." && match(name, /^[0-9a-f]+$/)) {
            push(out, name);
        }
    }
    return out;
};

function clientOrder(cid)
{
    return int(trim(fs.readfile(`${clientDir(cid)}/order`) || "0"));
};

function sortedClients()
{
    const ids = listClientIds();
    // Insertion sort by order (small N).
    for (let i = 1; i < length(ids); i++) {
        const key = ids[i];
        const ko = clientOrder(key);
        let j = i - 1;
        while (j >= 0 && clientOrder(ids[j]) > ko) {
            ids[j + 1] = ids[j];
            j--;
        }
        ids[j + 1] = key;
    }
    return ids;
};

function nextOrder()
{
    const n = int(trim(fs.readfile(`${SHELL_DIR}/next_order`) || "0")) + 1;
    fs.writefile(`${SHELL_DIR}/next_order`, `${n}`);
    return n;
};

function removeClientFiles(cid)
{
    if (validId(cid)) {
        system(`rm -rf '${clientDir(cid)}'`);
    }
};

export function promotePrimary()
{
    const ids = sortedClients();
    if (length(ids) == 0) {
        return null;
    }
    let primary = null;
    for (let i = 0; i < length(ids); i++) {
        if (primary == null) {
            primary = ids[i];
            writeRole(ids[i], "primary");
        }
        else {
            writeRole(ids[i], "viewer");
        }
    }
    return primary;
};

function killShell()
{
    // Hard-kill every helper / leftover ash from this package (old layouts included).
    system("ps w 2>/dev/null | grep aredn-terminal-session | grep -v grep | while read pid rest; do kill -9 \"$pid\" 2>/dev/null; done");
    system("ps w 2>/dev/null | grep '/bin/ash -l' | grep -v grep | while read pid rest; do kill -9 \"$pid\" 2>/dev/null; done");
    system("ps w 2>/dev/null | grep 'tail -f /tmp/aredn-terminal' | grep -v grep | while read pid rest; do kill -9 \"$pid\" 2>/dev/null; done");
    if (fs.stat(SHELL_DIR)) {
        const pid = trim(fs.readfile(`${SHELL_DIR}/pid`) || "");
        if (pid && match(pid, /^[0-9]+$/)) {
            system(`kill -9 ${pid} 2>/dev/null`);
        }
        const wrap = trim(fs.readfile(`${SHELL_DIR}/wrapper`) || "");
        if (wrap && match(wrap, /^[0-9]+$/)) {
            system(`kill -9 ${wrap} 2>/dev/null`);
        }
    }
    system(`rm -rf '${SESSION_ROOT}'`);
    clearBadge();
};

export function refreshBadge()
{
    if (shellAlive() && length(listClientIds()) > 0) {
        setBadge(true);
    }
    else {
        clearBadge();
    }
};

function spawnShell()
{
    // Always start from a clean process table / tmp tree.
    killShell();
    system("sleep 1");
    ensureDir(SESSION_ROOT);
    ensureDir(SHELL_DIR);
    ensureDir(CLIENTS_DIR);
    fs.writefile(`${SHELL_DIR}/next_order`, "0");
    system(`setsid /usr/libexec/aredn-terminal-session '${SHELL_DIR}' >/dev/null 2>&1 &`);
    system("sleep 1");
    return shellAlive();
};

function createClient(role)
{
    const cid = newId();
    const dir = clientDir(cid);
    ensureDir(CLIENTS_DIR);
    ensureDir(dir);
    writeRole(cid, role);
    fs.writefile(`${dir}/order`, `${nextOrder()}`);
    touchClient(cid);

    const st = fs.stat(`${SHELL_DIR}/stdout`);
    let offset = 0;
    if (st && st.size > VIEWER_CATCHUP) {
        offset = st.size - VIEWER_CATCHUP;
    }
    // Primary joining a fresh shell starts at 0; viewers joining live get catch-up tail.
    if (role == "primary" && (!st || st.size == 0)) {
        offset = 0;
    }
    fs.writefile(`${dir}/offset`, `${offset}`);
    return cid;
};

export function cleanupStale()
{
    ensureDir(SESSION_ROOT);
    if (!fs.stat(SHELL_DIR)) {
        clearBadge();
        return;
    }
    if (!shellAlive()) {
        killShell();
        return;
    }

    const now = clock()[0];
    const ids = listClientIds();
    let primaryGone = false;
    for (let i = 0; i < length(ids); i++) {
        const cid = ids[i];
        const hb = int(trim(fs.readfile(`${clientDir(cid)}/heartbeat`) || "0"));
        if (hb > 0 && now - hb > IDLE_SECS) {
            if (readRole(cid) == "primary") {
                primaryGone = true;
            }
            removeClientFiles(cid);
        }
    }

    const left = listClientIds();
    if (length(left) == 0) {
        killShell();
        return;
    }

    let hasPrimary = false;
    for (let i = 0; i < length(left); i++) {
        if (readRole(left[i]) == "primary") {
            hasPrimary = true;
            break;
        }
    }
    if (!hasPrimary || primaryGone) {
        promotePrimary();
    }
    refreshBadge();
};

/**
 * Join existing shell as viewer, or create shell + join as primary.
 */
export function joinSession()
{
    cleanupStale();

    if (shellAlive()) {
        const cid = createClient("viewer");
        // Ensure someone is primary (e.g. after races).
        let hasPrimary = false;
        const ids = listClientIds();
        for (let i = 0; i < length(ids); i++) {
            if (readRole(ids[i]) == "primary") {
                hasPrimary = true;
                break;
            }
        }
        if (!hasPrimary) {
            promotePrimary();
        }
        refreshBadge();
        return { sid: "active", cid: cid, role: readRole(cid) };
    }

    system(`rm -rf '${SESSION_ROOT}'`);
    if (!spawnShell()) {
        system(`rm -rf '${SESSION_ROOT}'`);
        return { error: "spawn", message: "Failed to start shell session" };
    }
    const cid = createClient("primary");
    setBadge(true);
    return { sid: "active", cid: cid, role: "primary" };
};

export function leaveClient(cid)
{
    cleanupStale();
    if (!validId(cid)) {
        return { error: "bad_request" };
    }
    if (!fs.stat(clientDir(cid))) {
        if (length(listClientIds()) == 0) {
            killShell();
        }
        else {
            refreshBadge();
        }
        return { ok: true };
    }

    const wasPrimary = readRole(cid) == "primary";
    removeClientFiles(cid);

    const left = listClientIds();
    if (length(left) == 0) {
        killShell();
        return { ok: true, closed: true };
    }
    if (wasPrimary) {
        promotePrimary();
    }
    refreshBadge();
    return { ok: true, closed: false };
};

/** Tear down entire shell (admin / last-resort). */
export function stopAll()
{
    killShell();
    return { ok: true };
};

export function takeover(cid)
{
    cleanupStale();
    if (!validId(cid) || !fs.stat(clientDir(cid))) {
        return { error: "gone" };
    }
    if (!shellAlive()) {
        return { error: "gone" };
    }
    touchClient(cid);
    const ids = listClientIds();
    for (let i = 0; i < length(ids); i++) {
        writeRole(ids[i], ids[i] == cid ? "primary" : "viewer");
    }
    return { ok: true, role: "primary", cid: cid, sid: "active" };
};

export function writeSession(cid, data)
{
    if (!validId(cid) || data == null) {
        return { error: "bad_request" };
    }
    if (!shellAlive() || !fs.stat(clientDir(cid))) {
        return { error: "gone" };
    }
    touchClient(cid);
    if (readRole(cid) != "primary") {
        return { error: "readonly", message: "Viewer mode — take control to type" };
    }
    // xterm sends CR for Enter; ash without a PTY expects LF.
    data = replace(data, /\r\n/g, "\n");
    data = replace(data, /\r/g, "\n");

    // Append to infile; session helper's `tail -f` feeds ash (never blocks CGI on a FIFO).
    const f = fs.open(`${SHELL_DIR}/infile`, "a");
    if (!f) {
        return { error: "write" };
    }
    f.write(data);
    f.close();
    return { ok: true, role: "primary" };
};

export function readSession(cid)
{
    if (!validId(cid)) {
        return { error: "bad_request" };
    }
    if (!shellAlive() || !fs.stat(clientDir(cid))) {
        cleanupStale();
        return { error: "gone" };
    }
    touchClient(cid);
    const dir = clientDir(cid);
    const offset = int(trim(fs.readfile(`${dir}/offset`) || "0"));
    const f = fs.open(`${SHELL_DIR}/stdout`, "r");
    if (!f) {
        return { data: "", offset: offset, role: readRole(cid), cid: cid };
    }
    f.seek(offset);
    const chunk = f.read("all") || "";
    const st = fs.stat(`${SHELL_DIR}/stdout`);
    const newOffset = st ? st.size : offset + length(chunk);
    f.close();
    fs.writefile(`${dir}/offset`, `${newOffset}`);
    return {
        data: chunk,
        offset: newOffset,
        alive: true,
        role: readRole(cid),
        cid: cid,
        sid: "active"
    };
};

export function pingClient(cid)
{
    if (!validId(cid) || !fs.stat(clientDir(cid))) {
        return { error: "gone" };
    }
    touchClient(cid);
    return { ok: true, role: readRole(cid), cid: cid };
};

// Back-compat aliases used by older call sites during transition.
export function listSessions()
{
    return listClientIds();
};

export function stopSession(cid)
{
    return leaveClient(cid);
};

export function touchHeartbeat(cid)
{
    if (validId(cid) && fs.stat(clientDir(cid))) {
        touchClient(cid);
    }
};

export function readPostBody()
{
    const cl = int(getenv("CONTENT_LENGTH") || "0");
    if (cl <= 0) {
        return "";
    }
    const max = cl > 65536 ? 65536 : cl;
    // Prefer the CGI stdin fd; /dev/stdin is unreliable under some uhttpd setups.
    let f = fs.open("/proc/self/fd/0", "r");
    if (!f) {
        f = fs.open("/dev/stdin", "r");
    }
    if (!f) {
        return "";
    }
    const body = f.read(max) || "";
    f.close();
    return body;
};

// CGI ucode has no global urldecode; decode %XX and +.
export function urlDecode(s)
{
    if (s == null || s === "") {
        return "";
    }
    s = replace(`${s}`, /\+/g, " ");
    let out = "";
    for (let i = 0; i < length(s); ) {
        const ch = substr(s, i, 1);
        if (ch == "%" && i + 2 < length(s)) {
            out += chr(hex(substr(s, i + 1, 2)));
            i += 3;
        }
        else {
            out += ch;
            i++;
        }
    }
    return out;
};

export function parseQuery(q)
{
    const out = {};
    if (!q) {
        return out;
    }
    const parts = split(q, "&");
    for (let i = 0; i < length(parts); i++) {
        const kv = split(parts[i], "=");
        if (length(kv) >= 1 && kv[0] !== "") {
            out[kv[0]] = length(kv) > 1 ? urlDecode(kv[1]) : "";
        }
    }
    return out;
};

export function jsonEscape(s)
{
    s = replace(s, /\\/g, "\\\\");
    s = replace(s, /"/g, "\\\"");
    s = replace(s, /\n/g, "\\n");
    s = replace(s, /\r/g, "\\r");
    s = replace(s, /\t/g, "\\t");
    return s;
};
