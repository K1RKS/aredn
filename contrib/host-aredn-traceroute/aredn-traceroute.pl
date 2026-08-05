#!/usr/bin/env perl
# Fast AREDN hop-name resolver for a Linux host on the mesh.
# Runs traceroute, then names each hop from /a/sysinfo (and prev-hop LQM if needed).
use strict;
use warnings;
use JSON::PP qw(decode_json);
use POSIX qw(_exit);

use constant VERSION       => '0.1.3';
use constant FETCH_TIMEOUT => 1;
use constant MAX_FETCHERS  => 8;

my $verbose      = 0;
my $gps          = 0;
my $node_version = 0;
my $dest;

sub usage {
    print <<'EOF';
Usage: aredn-traceroute.pl [options] <destination>
  Fast traceroute from this Linux host with AREDN hop names from each node's
  /a/sysinfo (one fetch per hop, in parallel). No Babel metrics. No link-cost
  columns. Names also fall back to the previous hop's LQM neighbor list.

  Example:
    1 K1RKS-X86-QTH (10.101.28.3) 1 ms
    2 K1RKS-Tunnel-Server (10.50.43.211) 2 ms

  -gps              Include per-hop GPS (lat,lon) after RTT
  --node_version    Append firmware_version from sysinfo
  -verbose          Show where each name came from
  -h / --help       This help
EOF
}

for my $a (@ARGV) {
    if ($a eq '-h' || $a eq '--help') {
        usage();
        exit 0;
    }
    if ($a eq '-verbose' || $a eq '--verbose' || $a eq '-v') {
        $verbose = 1;
        next;
    }
    if ($a eq '-gps' || $a eq '--gps') {
        $gps = 1;
        next;
    }
    if ($a eq '-node_version' || $a eq '--node_version' || $a eq '--node-version') {
        $node_version = 1;
        next;
    }
    # Accept old flags as no-ops so existing aliases keep working.
    if ($a eq '-tx_rx_info' || $a eq '--tx_rx_info' || $a eq '--tx-rx-info'
        || $a eq '-no_tx_rx_info' || $a eq '--no_tx_rx_info'
        || $a eq '--no-tx-rx-info' || $a eq '-no-tx-rx-info')
    {
        next;
    }
    if ($a =~ /^-/) {
        print "Unknown option: $a\n";
        usage();
        exit 1;
    }
    if (defined $dest) {
        print "Only one destination is allowed\n";
        usage();
        exit 1;
    }
    $dest = $a;
}

if (!defined $dest) {
    usage();
    exit 1;
}
if ($dest =~ /[^0-9a-zA-Z.\-]/) {
    print "Illegal destination name\n";
    exit 1;
}
if ($dest !~ /\./ && $dest !~ /^[0-9.]+$/) {
    $dest = "$dest.local.mesh";
}

# ---------------------------------------------------------------------------

sub is_ipv4 {
    my ($s) = @_;
    return defined $s && $s =~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/;
}

sub mesh_host {
    my ($name) = @_;
    return undef if !defined $name || $name eq '' || $name eq '*';
    return $name if is_ipv4($name);
    return "$name.local.mesh" if $name !~ /\./;
    return $name;
}

sub short_mesh_name {
    my ($name) = @_;
    return $name if !defined $name;
    $name =~ s/\.local\.mesh$//;
    return $name;
}

sub cache_key {
    my ($host_or_ip) = @_;
    return undef if !defined $host_or_ip || $host_or_ip eq '';
    return $host_or_ip if is_ipv4($host_or_ip);
    my $k = lc $host_or_ip;
    $k =~ s/\.local\.mesh$//;
    return $k;
}

sub _have_cmd {
    my ($name) = @_;
    for my $dir (split /:/, ($ENV{PATH} // '')) {
        return 1 if $dir ne '' && -x "$dir/$name";
    }
    return 0;
}

sub fetch_json {
    my ($url) = @_;
    my $timeout = FETCH_TIMEOUT;
    my $body;
    my $ok;
    if (_have_cmd('curl')) {
        if (open my $fh, '-|', 'curl', '-sS', '-m', "$timeout", '--fail',
            '--connect-timeout', "$timeout", $url)
        {
            local $/;
            $body = <$fh>;
            $ok = close $fh;
        }
    }
    elsif (_have_cmd('wget')) {
        if (open my $fh, '-|', 'wget', '-q', '-T', "$timeout", '-t', '1', '-O', '-', $url) {
            local $/;
            $body = <$fh>;
            $ok = close $fh;
        }
    }
    else {
        warn "aredn-traceroute.pl: neither curl nor wget found in PATH\n" if $verbose;
        return undef;
    }
    return undef if !$ok || !defined $body || $body eq '';
    my $info;
    eval { $info = decode_json($body); 1 } or return undef;
    return $info;
}

sub index_trackers {
    my ($trackers) = @_;
    my %by_ip;
    my %by_host;
    return (\%by_ip, \%by_host) if !$trackers || ref $trackers ne 'HASH';
    for my $mac (keys %$trackers) {
        my $t = $trackers->{$mac};
        next if !$t;
        $by_ip{ $t->{ip} } = $t if $t->{ip};
        if ($t->{canonical_ip} && (!$t->{ip} || $t->{canonical_ip} ne $t->{ip})) {
            $by_ip{ $t->{canonical_ip} } = $t;
        }
        if ($t->{hostname}) {
            $by_host{ lc $t->{hostname} } = $t;
            if ($t->{hostname} =~ /^([^.]+)/) {
                $by_host{ lc $1 } = $t;
            }
        }
    }
    return (\%by_ip, \%by_host);
}

sub parse_hop_line {
    my ($line) = @_;
    $line =~ s/^\s+|\s+$//g;
    return undef if $line eq '';

    if ($line =~ /^([0-9]+)\s+\*(?:\s+\*\s+\*)?\s*$/
        || $line =~ /^([0-9]+)\s+\*\s+\*\s+\*/)
    {
        return { hop => int($1), unreachable => 1 };
    }
    # GNU inetutils: "12.3ms" or "12.3 ms"
    if ($line =~ /^([0-9]+)\s+(\S+)\s+\(([0-9.]+)\)\s+([0-9.]+)\s*ms/) {
        return {
            hop         => int($1),
            hostname    => $2,
            ip          => $3,
            rtt         => $4,
            unreachable => 0,
        };
    }
    if ($line =~ /^([0-9]+)\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\s+([0-9.]+)\s*ms/) {
        return {
            hop         => int($1),
            hostname    => $2,
            ip          => $2,
            rtt         => $3,
            unreachable => 0,
        };
    }
    return undef;
}

sub format_hop_line {
    my ($hop_num, $hostname, $ip, $rtt, $lat, $lon, $fw) = @_;
    my $host = short_mesh_name($hostname || $ip || '?');
    my $ip_part = $ip ? " ($ip)" : '';
    my $rtt_part = '';
    if (defined $rtt && $rtt ne '') {
        if ($rtt =~ /^-?\d+(?:\.\d+)?$/) {
            $rtt_part = sprintf(' %d ms', int($rtt + 0.5));
        }
        else {
            $rtt_part = " $rtt ms";
        }
    }
    my $line = " $hop_num $host$ip_part$rtt_part";
    if ($gps) {
        if (defined $lat && defined $lon && $lat ne '' && $lon ne '') {
            $line .= " $lat,$lon";
        }
        else {
            $line .= ' -';
        }
    }
    if ($node_version) {
        $line .= ' ' . ( (defined $fw && $fw ne '') ? $fw : '-' );
    }
    return $line;
}

sub entry_from_sysinfo {
    my ($host_or_ip, $info) = @_;
    my $key = cache_key($host_or_ip);
    if (!$info) {
        return {
            key      => $key,
            failed   => 1,
            hostname => $host_or_ip,
            ip       => is_ipv4($host_or_ip) ? $host_or_ip : undef,
            byIp     => {},
            byHost   => {},
        };
    }
    my $trackers = {};
    if ($info->{lqm} && $info->{lqm}{info} && $info->{lqm}{info}{trackers}) {
        $trackers = $info->{lqm}{info}{trackers};
    }
    my ($by_ip, $by_host) = index_trackers($trackers);
    my $hostname = $info->{node} || $info->{hostname} || $host_or_ip;
    my $ip = $info->{ip} || (is_ipv4($host_or_ip) ? $host_or_ip : undef);
    my $fw;
    if ($info->{node_details} && $info->{node_details}{firmware_version}) {
        $fw = $info->{node_details}{firmware_version};
    }
    return {
        key             => $key,
        failed          => 0,
        hostname        => $hostname,
        ip              => $ip,
        lat             => $info->{lat},
        lon             => $info->{lon},
        firmwareVersion => $fw,
        byIp            => $by_ip,
        byHost          => $by_host,
    };
}

sub find_neighbor {
    my ($entry, $next_ip, $next_host) = @_;
    return undef if !$entry || $entry->{failed};
    return $entry->{byIp}{$next_ip} if $next_ip && $entry->{byIp}{$next_ip};
    if ($next_host) {
        my $h = lc $next_host;
        $h =~ s/\.local\.mesh$//;
        return $entry->{byHost}{$h} if $entry->{byHost}{$h};
        return $entry->{byHost}{ lc $next_host } if $entry->{byHost}{ lc $next_host };
    }
    return undef;
}

# Fetch many hop IPs in parallel (one HTTP GET each). Returns ip => entry.
sub fetch_all_sysinfo {
    my (@ips) = @_;
    my %want = map { $_ => 1 } grep { is_ipv4($_) } @ips;
    return {} if !%want;

    my $tmpdir = "/tmp/aredn-tr-$$";
    mkdir $tmpdir or die "mkdir $tmpdir: $!\n";

    my @queue = sort keys %want;
    my %pid_to_ip;
    my %results;

    my $start_one = sub {
        my ($ip) = @_;
        my $pid = fork;
        if (!defined $pid) {
            warn "fork failed: $!\n";
            return;
        }
        if ($pid == 0) {
            my $url  = "http://$ip/a/sysinfo?lqm=1";
            my $info = fetch_json($url);
            my $path = "$tmpdir/$ip.json";
            if ($info) {
                if (open my $fh, '>', $path) {
                    print {$fh} JSON::PP->new->utf8->encode($info);
                    close $fh;
                }
            }
            else {
                # Mark failure with empty file so parent knows we tried.
                if (open my $fh, '>', "$tmpdir/$ip.fail") {
                    close $fh;
                }
            }
            _exit(0);
        }
        $pid_to_ip{$pid} = $ip;
    };

    while (@queue || %pid_to_ip) {
        while (@queue && keys(%pid_to_ip) < MAX_FETCHERS) {
            $start_one->(shift @queue);
        }
        my $pid = wait;
        last if $pid < 0;
        my $ip = delete $pid_to_ip{$pid};
        next if !defined $ip;
        if (-f "$tmpdir/$ip.json") {
            if (open my $fh, '<', "$tmpdir/$ip.json") {
                local $/;
                my $body = <$fh>;
                close $fh;
                my $info;
                eval { $info = decode_json($body); 1 };
                $results{$ip} = entry_from_sysinfo($ip, $info);
            }
        }
        else {
            $results{$ip} = entry_from_sysinfo($ip, undef);
        }
    }

    # Cleanup
    unlink glob("$tmpdir/*");
    rmdir $tmpdir;

    return \%results;
}

sub resolve_name {
    my ($hop, $node, $prev) = @_;

    if ($node && !$node->{failed} && $node->{hostname} && !is_ipv4($node->{hostname})) {
        my $name = $node->{hostname};
        $name = "$name.local.mesh" if $name !~ /\./;
        return { name => $name, source => 'sysinfo' };
    }

    if ($prev && !$prev->{failed}) {
        my $tracker = find_neighbor($prev, $hop->{ip}, $hop->{hostname});
        if (!$tracker && $node && $node->{ip}) {
            $tracker = find_neighbor($prev, $node->{ip}, undef);
        }
        if ($tracker && $tracker->{hostname} && !is_ipv4($tracker->{hostname})) {
            my $name = $tracker->{hostname};
            $name = "$name.local.mesh" if $name !~ /\./;
            my $from = $prev->{hostname} || $prev->{ip} || '?';
            return { name => $name, source => 'previous_lqm', from => $from };
        }
    }

    my $name = $hop->{hostname};
    if ($name && !is_ipv4($name) && $name ne ($hop->{ip} // '')) {
        $name = "$name.local.mesh" if $name !~ /\./;
        return { name => $name, source => 'traceroute' };
    }
    return { name => $hop->{hostname} || $hop->{ip}, source => 'unresolved' };
}

# ---------------------------------------------------------------------------
# Main: traceroute once, parallel sysinfo, then print names
# ---------------------------------------------------------------------------

my @preamble;
my @hops;
my $cmd = "traceroute -q 1 -w 1 -m 30 \Q$dest\E 2>&1";
open my $tr, '-|', $cmd or do {
    print "Failed to run traceroute: $!\n";
    exit 1;
};
while (my $line = <$tr>) {
    chomp $line;
    $line =~ s/\r$//;
    my $hop = parse_hop_line($line);
    if ($hop) {
        push @hops, $hop;
    }
    else {
        push @preamble, $line;
    }
}
close $tr;

print "$_\n" for @preamble;
print 'Aredn-Traceroute-Host(' . VERSION . "): AREDN names\n";

my @fetch_ips;
for my $h (@hops) {
    next if $h->{unreachable};
    push @fetch_ips, $h->{ip} if $h->{ip};
}
my $by_ip = fetch_all_sysinfo(@fetch_ips);

my $prev;
for my $hop (@hops) {
    if ($hop->{unreachable}) {
        print " $hop->{hop}  * * *\n";
        print "    # unreachable\n" if $verbose;
        next;
    }

    my $node = $hop->{ip} ? $by_ip->{ $hop->{ip} } : undef;
    my $resolved = resolve_name($hop, $node, $prev);
    my $hostname = $resolved->{name};
    my $lat = ($gps && $node) ? $node->{lat} : undef;
    my $lon = ($gps && $node) ? $node->{lon} : undef;
    my $fw  = $node ? $node->{firmwareVersion} : undef;

    print format_hop_line($hop->{hop}, $hostname, $hop->{ip}, $hop->{rtt}, $lat, $lon, $fw), "\n";

    if ($verbose) {
        if ($resolved->{source} eq 'sysinfo') {
            my $mesh = ($node && $node->{ip}) ? " meshIP=$node->{ip}" : '';
            print "    # name from sysinfo$mesh\n";
        }
        elsif ($resolved->{source} eq 'previous_lqm') {
            print "    # name from previous hop $resolved->{from} LQM\n";
        }
        elsif ($resolved->{source} eq 'traceroute') {
            print "    # name from traceroute PTR (no AREDN sysinfo)\n";
        }
        else {
            print "    # name unresolved for $hop->{ip}\n";
        }
    }

    # Keep successful (or failed) entry as previous for LQM name fallback.
    if ($node && !$node->{failed}) {
        $node->{displayName} = $hostname if $hostname && !is_ipv4($hostname);
        $prev = $node;
    }
    elsif ($hostname && !is_ipv4($hostname)) {
        # Synthetic prev with only hostname so chain can continue poorly.
        $prev = $node if $node;
    }
}

exit 0;
