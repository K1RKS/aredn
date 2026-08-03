#!/bin/sh
# Inject / remove Waterfall entry in Tools menu (/app/partial/tools.ut).
TOOLS_UT=/app/partial/tools.ut
MARKER='<!-- waterfall-tools-menu -->'
MENU_LINE='            <div hx-trigger="click" hx-get="tools/e/waterfall" hx-target="#ctrl-modal"><div class="icon signal"></div>Waterfall</div> '"$MARKER"

has_entry() {
    [ -f "$TOOLS_UT" ] && grep -q 'waterfall-tools-menu' "$TOOLS_UT" 2>/dev/null
}

remove_menu_entry() {
    [ -f "$TOOLS_UT" ] || return 0
    if ! has_entry; then
        return 0
    fi
    grep -v 'waterfall-tools-menu' "$TOOLS_UT" > "${TOOLS_UT}.waterfall.tmp" && mv "${TOOLS_UT}.waterfall.tmp" "$TOOLS_UT"
}

install_tools_menu() {
    [ -f "$TOOLS_UT" ] || return 0
    remove_menu_entry
    if grep -q 'tools/e/wifiscan' "$TOOLS_UT" 2>/dev/null; then
        awk -v line="$MENU_LINE" '
            { print }
            /tools\/e\/wifiscan/ && !done {
                print line
                done=1
            }
        ' "$TOOLS_UT" > "${TOOLS_UT}.waterfall.tmp" && mv "${TOOLS_UT}.waterfall.tmp" "$TOOLS_UT"
    elif grep -q 'tools/e/traceroute' "$TOOLS_UT" 2>/dev/null; then
        awk -v line="$MENU_LINE" '
            { print }
            /tools\/e\/traceroute/ && !done {
                print line
                done=1
            }
        ' "$TOOLS_UT" > "${TOOLS_UT}.waterfall.tmp" && mv "${TOOLS_UT}.waterfall.tmp" "$TOOLS_UT"
    else
        awk -v line="$MENU_LINE" '
            /tools\/e\/iperf3/ && !done {
                print
                print line
                done=1
                next
            }
            { print }
        ' "$TOOLS_UT" > "${TOOLS_UT}.waterfall.tmp" && mv "${TOOLS_UT}.waterfall.tmp" "$TOOLS_UT"
    fi
}

remove_tools_menu() {
    [ -f "$TOOLS_UT" ] || return 0
    remove_menu_entry
}
