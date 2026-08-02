#!/bin/sh
# Inject / remove StableRoute entry in Tools menu (/app/partial/tools.ut).
TOOLS_UT=/app/partial/tools.ut
MARKER='<!-- stableroute-tools-menu -->'
MENU_LINE='            <div hx-trigger="click" hx-get="tools/e/stableroute" hx-target="#ctrl-modal"><div class="icon plane"></div>StableRoute</div> '"$MARKER"

has_entry() {
    [ -f "$TOOLS_UT" ] && grep -q 'stableroute-tools-menu' "$TOOLS_UT" 2>/dev/null
}

install_tools_menu() {
    [ -f "$TOOLS_UT" ] || return 0
    if has_entry; then
        return 0
    fi
    if grep -q 'tools/e/traceroute' "$TOOLS_UT" 2>/dev/null; then
        # Insert StableRoute immediately after Traceroute menu item.
        awk -v line="$MENU_LINE" '
            { print }
            /tools\/e\/traceroute/ && !done {
                print line
                done=1
            }
        ' "$TOOLS_UT" > "${TOOLS_UT}.stableroute.tmp" && mv "${TOOLS_UT}.stableroute.tmp" "$TOOLS_UT"
    else
        # Fallback: before Support Data / closing menu if traceroute line missing.
        awk -v line="$MENU_LINE" '
            /tools\/e\/iperf3/ && !done {
                print
                print line
                done=1
                next
            }
            { print }
        ' "$TOOLS_UT" > "${TOOLS_UT}.stableroute.tmp" && mv "${TOOLS_UT}.stableroute.tmp" "$TOOLS_UT"
    fi
}

remove_tools_menu() {
    [ -f "$TOOLS_UT" ] || return 0
    if ! has_entry; then
        return 0
    fi
    grep -v 'stableroute-tools-menu' "$TOOLS_UT" > "${TOOLS_UT}.stableroute.tmp" && mv "${TOOLS_UT}.stableroute.tmp" "$TOOLS_UT"
}
