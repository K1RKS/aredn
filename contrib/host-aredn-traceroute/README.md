# Host-side AREDN traceroute (Perl)

Fast Linux CLI for a machine already on the AREDN mesh. Goal: **resolve AREDN
node names** on the path from this host. No Babel metrics. No link-cost columns.

```sh
./aredn-traceroute.pl ah6le-x86-parrett
./aredn-traceroute.pl -verbose nodeD.local.mesh
```

## Requirements

- Perl 5.14+ (`JSON::PP`)
- `traceroute` on `PATH`
- `curl` or `wget`
- Mesh routing so hop IPs answer HTTP

## How it stays fast

1. `traceroute -q 1 -w 1 -m 30` (inetutils does not PTR by default; names come from AREDN).
2. One `GET http://{hopIp}/a/sysinfo?lqm=1` per hop, **in parallel** (up to 8).
3. 1s HTTP timeout; failed hops are not retried via hostname.
4. Display name: sysinfo `node`, else previous hop’s LQM neighbor hostname.

Example:

```text
traceroute to ah6le-x86-parrett.local.mesh (10.206.62.244), 30 hops max
Aredn-Traceroute-Host(0.1.3): AREDN names
 1 K1RKS-X86-QTH (10.101.28.3) 0 ms
 2 K1RKS-Tunnel-Server (10.50.43.211) 1 ms
 3 K9RCP-WVMN (172.31.59.72) 7 ms
```

## Options

| Flag | Meaning |
|------|---------|
| `-gps` | Append `lat,lon` (or `-`) |
| `--node_version` | Append firmware version |
| `-verbose` | Show name source |
| `-h` | Help |

Old `-tx_rx_info` / `-no_tx_rx_info` flags are ignored (no-ops).

## vs node APK

Use [`contrib/aredn-traceroute`](../aredn-traceroute/) on a node for Babel metrics,
link type/tx-rx, and Tools → Traceroute. Use this script for **names from your
Linux host’s path**.
