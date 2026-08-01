#!/bin/sh
# Shared paths for aredn-traceroute CGI swap (sourced by install scripts).
OURS=/usr/share/aredn-traceroute/cgi-bin-traceroute
DEFAULT=/usr/share/aredn-traceroute/traceroute.firmware.default
CGI=/www/cgi-bin/traceroute
BACKUP=/etc/aredn-traceroute/traceroute.firmware

is_ours() {
    [ -f "$1" ] && grep -q 'aredn_traceroute' "$1" 2>/dev/null
}

backup_stock_cgi() {
    mkdir -p /etc/aredn-traceroute
    if [ -f "$CGI" ] && [ ! -f "$BACKUP" ] && ! is_ours "$CGI"; then
        cp -a "$CGI" "$BACKUP"
    fi
}

install_ours_cgi() {
    if [ -f "$OURS" ]; then
        cp -a "$OURS" "$CGI"
        chmod 755 "$CGI"
    fi
}

restore_stock_cgi() {
    if [ -f "$BACKUP" ]; then
        cp -a "$BACKUP" "$CGI"
        chmod 755 "$CGI"
        return 0
    fi
    if [ -f "$DEFAULT" ]; then
        cp -a "$DEFAULT" "$CGI"
        chmod 755 "$CGI"
        return 0
    fi
    return 1
}
