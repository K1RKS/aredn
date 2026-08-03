/**
 * Client helper: send one command to babel-monitord, return parsed JSON.
 */
import * as socket from "socket";
import * as common from "babel_monitor.common";

export function query(cmd)
{
    const c = socket.connect({ path: common.SOCK_PATH });
    if (!c) {
        return null;
    }
    c.send(cmd + "\nquit\n");
    let d = "";
    for (;;) {
        const v = c.recv(8192);
        if (!v || v === "") {
            break;
        }
        d += v;
        /* stop once we have a complete JSON value (compact one-liner preferred) */
        if (index(d, "\n") >= 0) {
            break;
        }
    }
    c.close();
    d = trim(d);
    if (!length(d)) {
        return null;
    }
    const n = index(d, "\n");
    const line = n >= 0 ? substr(d, 0, n) : d;
    try {
        return json(line);
    }
    catch (e) {
        try {
            return json(d);
        }
        catch (e2) {
            return null;
        }
    }
};
