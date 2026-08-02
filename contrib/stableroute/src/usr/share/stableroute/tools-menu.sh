#!/bin/sh
# Inject / remove StableRoute entry + icon CSS in Tools menu (/app/partial/tools.ut).
TOOLS_UT=/app/partial/tools.ut
MARKER='<!-- stableroute-tools-menu -->'
ICON_MARKER='/* stableroute-tools-icon */'
ICON_CSS=/usr/share/stableroute/icon.css
MENU_LINE='            <div hx-trigger="click" hx-get="tools/e/stableroute" hx-target="#ctrl-modal"><div class="icon stableroute"></div>StableRoute</div> '"$MARKER"

has_entry() {
    [ -f "$TOOLS_UT" ] && grep -q 'stableroute-tools-menu' "$TOOLS_UT" 2>/dev/null
}

has_icon_css() {
    [ -f "$TOOLS_UT" ] && grep -q 'stableroute-tools-icon' "$TOOLS_UT" 2>/dev/null
}

remove_icon_css() {
    [ -f "$TOOLS_UT" ] || return 0
    if ! has_icon_css; then
        return 0
    fi
    awk '
        /stableroute-tools-icon/ {
            skipping = 1
            # Drop the opening <style> line that contains the marker.
            next
        }
        skipping {
            if ($0 ~ /<\/style>/) skipping = 0
            next
        }
        { print }
    ' "$TOOLS_UT" > "${TOOLS_UT}.stableroute.tmp" && mv "${TOOLS_UT}.stableroute.tmp" "$TOOLS_UT"
}

remove_menu_entry() {
    [ -f "$TOOLS_UT" ] || return 0
    if ! has_entry; then
        return 0
    fi
    grep -v 'stableroute-tools-menu' "$TOOLS_UT" > "${TOOLS_UT}.stableroute.tmp" && mv "${TOOLS_UT}.stableroute.tmp" "$TOOLS_UT"
}

install_icon_css() {
    [ -f "$TOOLS_UT" ] || return 0
    [ -f "$ICON_CSS" ] || return 0
    remove_icon_css
    awk -v cssfile="$ICON_CSS" -v marker="$ICON_MARKER" '
        BEGIN {
            while ((getline line < cssfile) > 0) {
                css = css line "\n"
            }
            close(cssfile)
        }
        { print }
        /id="tools"/ && !done {
            print "<style>" marker
            printf "%s", css
            print "</style>"
            done = 1
        }
    ' "$TOOLS_UT" > "${TOOLS_UT}.stableroute.tmp" && mv "${TOOLS_UT}.stableroute.tmp" "$TOOLS_UT"
}

install_tools_menu() {
    [ -f "$TOOLS_UT" ] || return 0
    # Re-apply cleanly so upgrades refresh icon CSS and class name.
    remove_menu_entry
    install_icon_css
    if grep -q 'tools/e/traceroute' "$TOOLS_UT" 2>/dev/null; then
        awk -v line="$MENU_LINE" '
            { print }
            /tools\/e\/traceroute/ && !done {
                print line
                done=1
            }
        ' "$TOOLS_UT" > "${TOOLS_UT}.stableroute.tmp" && mv "${TOOLS_UT}.stableroute.tmp" "$TOOLS_UT"
    else
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
    remove_menu_entry
    remove_icon_css
}
