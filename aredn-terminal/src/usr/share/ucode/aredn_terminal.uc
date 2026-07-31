/*
 * AREDN terminal session helpers: authV1, ash session I/O, apps-bar badges.
 * Side-loaded package companion for AREDN firmware.
 */

import * as fs from "fs";
import * as configuration from "aredn.configuration";

export const SESSION_ROOT = "/tmp/aredn-terminal";
export const BADGE_DIR = "/tmp/apps/terminal";
export const MAX_SESSIONS = 1;
export const IDLE_SECS = 60;
export const AUTH_AGE = 315360000; // 10 years (match stock UI)

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
        fs.unlink(`${BADGE_DIR}/badge`);
        fs.unlink(`${BADGE_DIR}/badge-color`);
    }
};

export function touchHeartbeat(sid)
{
    fs.writefile(`${SESSION_ROOT}/${sid}/heartbeat`, `${clock()[0]}`);
};

function sessionAlive(sid)
{
    const pid = trim(fs.readfile(`${SESSION_ROOT}/${sid}/pid`) || "");
    if (!pid || !match(pid, /^[0-9]+$/)) {
        return false;
    }
    return system(`kill -0 ${pid} 2>/dev/null`) === 0;
};

export function stopSession(sid)
{
    if (!sid || match(sid, /[^0-9a-f]/)) {
        return false;
    }
    const dir = `${SESSION_ROOT}/${sid}`;
    if (!fs.stat(dir)) {
        return false;
    }
    const pid = trim(fs.readfile(`${dir}/pid`) || "");
    if (pid && match(pid, /^[0-9]+$/)) {
        system(`kill ${pid} 2>/dev/null`);
        system(`kill -9 ${pid} 2>/dev/null`);
    }
    system(`pkill -f 'aredn-terminal-session ${dir}' 2>/dev/null`);
    system(`rm -rf '${dir}'`);
    refreshBadgeFromSessions();
    return true;
};

export function listSessions()
{
    const out = [];
    const entries = fs.lsdir(SESSION_ROOT);
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

export function refreshBadgeFromSessions()
{
    const sessions = listSessions();
    let busy = false;
    for (let i = 0; i < length(sessions); i++) {
        if (sessionAlive(sessions[i])) {
            busy = true;
            break;
        }
    }
    setBadge(busy);
};

export function cleanupStale()
{
    ensureDir(SESSION_ROOT);
    const now = clock()[0];
    const sessions = listSessions();
    for (let i = 0; i < length(sessions); i++) {
        const sid = sessions[i];
        const hb = int(trim(fs.readfile(`${SESSION_ROOT}/${sid}/heartbeat`) || "0"));
        if (!sessionAlive(sid) || (hb > 0 && now - hb > IDLE_SECS)) {
            stopSession(sid);
        }
    }
    refreshBadgeFromSessions();
};

function newSid()
{
    const t = clock();
    return sprintf("%08x%04x", t[0] & 0xffffffff, t[1] & 0xffff);
};

export function startSession()
{
    cleanupStale();
    const sessions = listSessions();
    let alive = 0;
    for (let i = 0; i < length(sessions); i++) {
        if (sessionAlive(sessions[i])) {
            alive++;
        }
    }
    if (alive >= MAX_SESSIONS) {
        return { error: "busy", message: "Terminal already in use" };
    }

    const sid = newSid();
    const dir = `${SESSION_ROOT}/${sid}`;
    ensureDir(SESSION_ROOT);
    ensureDir(dir);
    fs.writefile(`${dir}/offset`, "0");
    touchHeartbeat(sid);

    system(`setsid /usr/libexec/aredn-terminal-session '${dir}' >/dev/null 2>&1 &`);
    system("sleep 0.2 2>/dev/null || sleep 1");
    if (!sessionAlive(sid)) {
        system(`rm -rf '${dir}'`);
        return { error: "spawn", message: "Failed to start shell session" };
    }
    setBadge(true);
    return { sid: sid };
};

export function writeSession(sid, data)
{
    if (!sid || match(sid, /[^0-9a-f]/) || data == null) {
        return { error: "bad_request" };
    }
    if (!sessionAlive(sid)) {
        return { error: "gone" };
    }
    touchHeartbeat(sid);
    const f = fs.open(`${SESSION_ROOT}/${sid}/stdin`, "w");
    if (!f) {
        return { error: "write" };
    }
    f.write(data);
    f.close();
    return { ok: true };
};

export function readSession(sid)
{
    if (!sid || match(sid, /[^0-9a-f]/)) {
        return { error: "bad_request" };
    }
    if (!sessionAlive(sid)) {
        cleanupStale();
        return { error: "gone" };
    }
    touchHeartbeat(sid);
    const dir = `${SESSION_ROOT}/${sid}`;
    const offset = int(trim(fs.readfile(`${dir}/offset`) || "0"));
    const f = fs.open(`${dir}/stdout`, "r");
    if (!f) {
        return { data: "", offset: offset };
    }
    f.seek(offset);
    const chunk = f.read("all") || "";
    const st = fs.stat(`${dir}/stdout`);
    const newOffset = st ? st.size : offset + length(chunk);
    f.close();
    fs.writefile(`${dir}/offset`, `${newOffset}`);
    return { data: chunk, offset: newOffset, alive: true };
};

export function readPostBody()
{
    const cl = int(getenv("CONTENT_LENGTH") || "0");
    if (cl <= 0) {
        return "";
    }
    const max = cl > 65536 ? 65536 : cl;
    const f = fs.open("/dev/stdin", "r");
    if (!f) {
        return "";
    }
    const body = f.read(max) || "";
    f.close();
    return body;
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
            out[kv[0]] = length(kv) > 1 ? replace(kv[1], /\+/g, " ") : "";
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
