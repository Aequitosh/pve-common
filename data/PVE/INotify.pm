package PVE::INotify;

# todo: maybe we do not need update_file() ?

use strict;
use POSIX;
use IO::File;
use IO::Dir;
use File::stat;
use File::Basename;
use Fcntl qw(:DEFAULT :flock);
use PVE::SafeSyslog;
use PVE::Exception qw(raise_param_exc);
use PVE::Tools;
use Storable qw(dclone);            
use Linux::Inotify2;
use base 'Exporter';
use JSON; 

our @EXPORT_OK = qw(read_file write_file register_file);

my $ccache;
my $ccachemap;
my $ccacheregex;
my $inotify;
my $inotify_pid = 0;
my $versions;
my $shadowfiles = {
    '/etc/network/interfaces' => '/etc/network/interfaces.new',
};

# to enable cached operation, you need to call 'inotify_init'
# inotify handles are a limited resource, so use with care (only
# enable the cache if you really need it)

# Note: please close the inotify handle after you fork

sub ccache_default_writer {
    my ($filename, $data) = @_;

    die "undefined config writer for '$filename' :ERROR";
}

sub ccache_default_parser {
    my ($filename, $srcfd) = @_;

    die "undefined config reader for '$filename' :ERROR";
}

sub ccache_compute_diff {
    my ($filename, $shadow) = @_;

    my $diff = '';

    open (TMP, "diff -b -N -u '$filename' '$shadow'|");
	
    while (my $line = <TMP>) {
	$diff .= $line;
    }

    close (TMP);

    $diff = undef if !$diff;

    return $diff;
}

sub ccache_info {
    my ($filename) = @_;

    foreach my $uid (keys %$ccacheregex) {
	my $ccinfo = $ccacheregex->{$uid};
	my $dir = $ccinfo->{dir};
	my $regex = $ccinfo->{regex};
	if ($filename =~ m|^$dir/+$regex$|) {
	    if (!$ccache->{$filename}) {
		my $cp = {};
		while (my ($k, $v) = each %$ccinfo) {
		    $cp->{$k} = $v;
		}
		$ccache->{$filename} = $cp;
	    } 
	    return ($ccache->{$filename}, $filename);
	}
    }
 
    $filename = $ccachemap->{$filename} if defined ($ccachemap->{$filename});

    die "file '$filename' not added :ERROR" if !defined ($ccache->{$filename});
   
    return ($ccache->{$filename}, $filename);
}

sub write_file {
    my ($fileid, $data, $full) = @_;

    my ($ccinfo, $filename) = ccache_info($fileid);

    my $writer = $ccinfo->{writer};

    my $realname = $filename;

    my $shadow;
    if ($shadow = $shadowfiles->{$filename}) {
	$realname = $shadow;
    }

    my $perm = $ccinfo->{perm} || 0644;

    my $tmpname = "$realname.tmp.$$";

    my $res;
    eval {
	my $fh = IO::File->new($tmpname, O_WRONLY|O_CREAT, $perm);
	die "unable to open file '$tmpname' - $!\n" if !$fh;

	$res = &$writer($filename, $fh, $data);

	die "closing file '$tmpname' failed - $!\n" unless close $fh;
    };
    my $err = $@;

    $ccinfo->{version} = undef;

    if ($err) {
	unlink $tmpname;
	die $err;
    }

    if (!rename($tmpname, $realname)) {
	my $msg = "close (rename) atomic file '$filename' failed: $!\n";
	unlink $tmpname;
	die $msg;	
    }

    my $diff;
    if ($shadow && $full) {
	$diff = ccache_compute_diff ($filename, $shadow);
    }

    if ($full) {
	return { data => $res, changes => $diff };
    }

    return $res;
}

sub update_file {
    my ($fileid, $data, @args) = @_;

    my ($ccinfo, $filename) = ccache_info($fileid);

    my $update = $ccinfo->{update};

    die "unable to update/merge data" if !$update;

    my $lkfn = "$filename.lock";

    my $timeout = 10;

    my $fd;

    my $code = sub {

	$fd = IO::File->new ($filename, "r");
	
	my $new = &$update($filename, $fd, $data, @args);

	if (defined($new)) {
	    PVE::Tools::file_set_contents($filename, $new, $ccinfo->{perm});
	} else {
	    unlink $filename;
	}
    };

    PVE::Tools::lock_file($lkfn, $timeout, $code);
    my $err = $@;

    close($fd) if defined($fd);

    die $err if $err;

    return undef;
}

sub discard_changes {
    my ($fileid, $full) = @_;

    my ($ccinfo, $filename) = ccache_info($fileid);

    if (my $copy = $shadowfiles->{$filename}) {
	unlink $copy;
    }

    return read_file ($filename, $full);
}

sub read_file {
    my ($fileid, $full) = @_;

    my $parser;

    my ($ccinfo, $filename) = ccache_info($fileid);
     
    $parser = $ccinfo->{parser};
 
    my $fd;
    my $shadow;

    poll() if $inotify; # read new inotify events

    $versions->{$filename} = 0 if !defined ($versions->{$filename});

    my $cver = $versions->{$filename};

    if (my $copy = $shadowfiles->{$filename}) {
	if ($fd = IO::File->new ($copy, "r")) {
	    $shadow = $copy;
	} else {
	    $fd = IO::File->new ($filename, "r");
	}
    } else {
	$fd = IO::File->new ($filename, "r");
    }

    my $acp = $ccinfo->{always_call_parser};

    if (!$fd) {
	$ccinfo->{version} = undef;
	$ccinfo->{data} = undef; 
	$ccinfo->{diff} = undef;
	return undef if !$acp;
    }

    my $noclone = $ccinfo->{noclone};

    # file unchanged?
    if (!$ccinfo->{nocache} &&
	$inotify && $versions->{$filename} &&
	defined ($ccinfo->{data}) &&
	defined ($ccinfo->{version}) &&
	($ccinfo->{readonce} ||
	 ($ccinfo->{version} == $versions->{$filename}))) {

	my $ret;
	if (!$noclone && ref ($ccinfo->{data})) {
	    $ret->{data} = dclone ($ccinfo->{data});
	} else {
	    $ret->{data} = $ccinfo->{data};
	}
	$ret->{changes} = $ccinfo->{diff};
	
	return $full ? $ret : $ret->{data};
    }

    my $diff;

    if ($shadow) {
	$diff = ccache_compute_diff ($filename, $shadow);
    }

    my $res = &$parser($filename, $fd);

    if (!$ccinfo->{nocache}) {
	$ccinfo->{version} = $cver;
    }

    # we cache data with references, so we always need to
    # dclone this data. Else the original data may get
    # modified.
    $ccinfo->{data} = $res;

    # also store diff
    $ccinfo->{diff} = $diff;

    my $ret;
    if (!$noclone && ref ($ccinfo->{data})) {
	$ret->{data} = dclone ($ccinfo->{data});
    } else {
	$ret->{data} = $ccinfo->{data};
    }
    $ret->{changes} = $ccinfo->{diff};

    return $full ? $ret : $ret->{data};
}    

sub parse_ccache_options {
    my ($ccinfo, %options) = @_;

    foreach my $opt (keys %options) {
	my $v = $options{$opt};
	if ($opt eq 'readonce') {
	    $ccinfo->{$opt} = $v;
	} elsif ($opt eq 'nocache') {
	    $ccinfo->{$opt} = $v;
	} elsif ($opt eq 'shadow') {
	    $ccinfo->{$opt} = $v;
	} elsif ($opt eq 'perm') {
	    $ccinfo->{$opt} = $v;
	} elsif ($opt eq 'noclone') {
	    # noclone flag for large read-only data chunks like aplinfo
	    $ccinfo->{$opt} = $v;
	} elsif ($opt eq 'always_call_parser') {
	    # when set, we call parser even when the file does not exists.
	    # this allows the parser to return some default
	    $ccinfo->{$opt} = $v;
	} else {
	    die "internal error - unsupported option '$opt'";
	}
    }
}

sub register_file {
    my ($id, $filename, $parser, $writer, $update, %options) = @_;

    die "can't register file after initify_init" if $inotify;

    die "file '$filename' already added :ERROR" if defined ($ccache->{$filename});
    die "ID '$id' already used :ERROR" if defined ($ccachemap->{$id});

    my $ccinfo = {};

    $ccinfo->{id} = $id;
    $ccinfo->{parser} = $parser || \&ccache_default_parser;
    $ccinfo->{writer} = $writer || \&ccache_default_writer;
    $ccinfo->{update} = $update;

    parse_ccache_options($ccinfo, %options);
    
    if ($options{shadow}) {
	$shadowfiles->{$filename} = $options{shadow};
    }

    $ccachemap->{$id} = $filename;
    $ccache->{$filename} = $ccinfo;
}

sub register_regex {
    my ($dir, $regex, $parser, $writer, $update, %options) = @_;

    die "can't register regex after initify_init" if $inotify;

    my $uid = "$dir/$regex";
    die "regular expression '$uid' already added :ERROR" if defined ($ccacheregex->{$uid});
 
    my $ccinfo = {};

    $ccinfo->{dir} = $dir;
    $ccinfo->{regex} = $regex;
    $ccinfo->{parser} = $parser || \&ccache_default_parser;
    $ccinfo->{writer} = $writer || \&ccache_default_writer;
    $ccinfo->{update} = $update;

    parse_ccache_options($ccinfo, %options);

    $ccacheregex->{$uid} = $ccinfo;
}

sub poll {
    return if !$inotify;

    if ($inotify_pid != $$) {
	syslog ('err', "got inotify poll request in wrong process - disabling inotify");
	$inotify = undef;
    } else {
	1 while $inotify && $inotify->poll;
    }
}

sub flushcache {
    foreach my $filename (keys %$ccache) {
	$ccache->{$filename}->{version} = undef;
	$ccache->{$filename}->{data} = undef;
	$ccache->{$filename}->{diff} = undef;
    }
}

sub inotify_close {
    $inotify = undef;
}

sub inotify_init {

    die "only one inotify instance allowed" if $inotify;

    $inotify =  Linux::Inotify2->new()
	|| die "Unable to create new inotify object: $!";

    $inotify->blocking (0);

    $versions = {};

    my $dirhash = {};
    foreach my $fn (keys %$ccache) {
	my $dir = dirname ($fn);
	my $base = basename ($fn);

	$dirhash->{$dir}->{$base} = $fn;

	if (my $sf = $shadowfiles->{$fn}) {
	    $base = basename ($sf);
	    $dir = dirname ($sf);
	    $dirhash->{$dir}->{$base} = $fn; # change version of original file!
	}
    }

    foreach my $uid (keys %$ccacheregex) {
	my $ccinfo = $ccacheregex->{$uid};
	$dirhash->{$ccinfo->{dir}}->{_regex} = 1;	
    }

    $inotify_pid = $$;

    foreach my $dir (keys %$dirhash) {

	my $evlist = IN_MODIFY|IN_ATTRIB|IN_MOVED_FROM|IN_MOVED_TO|IN_DELETE|IN_CREATE;
	$inotify->watch ($dir, $evlist, sub {
	    my $e = shift;
	    my $name = $e->name;

	    if ($inotify_pid != $$) {
		syslog ('err', "got inotify event in wrong process");
	    }

	    if ($e->IN_ISDIR || !$name) {
		return;
	    }

	    if ($e->IN_Q_OVERFLOW) {
		syslog ('info', "got inotify overflow - flushing cache");
		flushcache();
		return;
	    }

	    if ($e->IN_UNMOUNT) {
		syslog ('err', "got 'unmount' event on '$name' - disabling inotify");
		$inotify = undef;
	    }
	    if ($e->IN_IGNORED) { 
		syslog ('err', "got 'ignored' event on '$name' - disabling inotify");
		$inotify = undef;
	    }

	    if ($dirhash->{$dir}->{_regex}) {
		foreach my $uid (keys %$ccacheregex) {
		    my $ccinfo = $ccacheregex->{$uid};
		    next if $dir ne $ccinfo->{dir};
		    my $regex = $ccinfo->{regex};
		    if ($regex && ($name =~ m|^$regex$|)) {

			my $fn = "$dir/$name";
			$versions->{$fn}++;
			#print "VERSION:$fn:$versions->{$fn}\n";
		    }
		}
	    } elsif (my $fn = $dirhash->{$dir}->{$name}) {

		$versions->{$fn}++;
		#print "VERSION:$fn:$versions->{$fn}\n";
	    }
	});
    }

    foreach my $dir (keys %$dirhash) {
	foreach my $name (keys %{$dirhash->{$dir}}) {
	    if ($name eq '_regex') {
		foreach my $uid (keys %$ccacheregex) {
		    my $ccinfo = $ccacheregex->{$uid};
		    next if $dir ne $ccinfo->{dir};
		    my $re = $ccinfo->{regex};
		    if (my $fd = IO::Dir->new ($dir)) {
			while (defined(my $de = $fd->read)) { 
			    if ($de =~ m/^$re$/) {
				my $fn = "$dir/$de";
				$versions->{$fn}++; # init with version
				#print "init:$fn:$versions->{$fn}\n";
			    }
			}
		    }
		}
	    } else {
		my $fn = $dirhash->{$dir}->{$name};
		$versions->{$fn}++; # init with version
		#print "init:$fn:$versions->{$fn}\n";
	    }
	}
    }
}

my $cached_nodename;

sub nodename {

    return $cached_nodename if $cached_nodename;

    my ($sysname, $nodename) = POSIX::uname();

    $nodename =~ s/\..*$//; # strip domain part, if any

    die "unable to read node name\n" if !$nodename;

    $cached_nodename = $nodename;

    return $cached_nodename;
}

sub read_etc_hostname {
    my ($filename, $fd) = @_;

    my $hostname = <$fd>;

    chomp $hostname;

    $hostname =~ s/\..*$//; # strip domain part, if any

    return $hostname;
}

sub write_etc_hostname {
    my ($filename, $fh, $hostname) = @_;

    die "write failed: $!" unless print $fh "$hostname\n";

    return $hostname;
}

register_file('hostname', "/etc/hostname",  
	      \&read_etc_hostname, 
	      \&write_etc_hostname);

sub read_etc_resolv_conf {
    my ($filename, $fh) = @_;

    my $res = {};

    my $nscount = 0;
    while (my $line = <$fh>) {
	chomp $line;
	if ($line =~ m/^(search|domain)\s+(\S+)\s*/) {
	    $res->{search} = $2;
	} elsif ($line =~ m/^nameserver\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s*/) {
	    $nscount++;
	    if ($nscount <= 3) {
		$res->{"dns$nscount"} = $1;
	    }
	}
    }

    return $res;
}

sub update_etc_resolv_conf {
    my ($filename, $fh, $resolv, @args) = @_;

    my $data = "";

    $data = "search $resolv->{search}\n"
	if $resolv->{search};

    my $written = {};
    foreach my $k ("dns1", "dns2", "dns3") {
	my $ns = $resolv->{$k};
	if ($ns && $ns ne '0.0.0.0' && !$written->{$ns}) {
	    $written->{$ns} = 1;
	    $data .= "nameserver $ns\n";
	}
    }

    while (my $line = <$fh>) {
	next if $line =~ m/^(search|domain|nameserver)\s+/;
	$data .= $line
    }
    
    return $data;
}

register_file('resolvconf', "/etc/resolv.conf", 
	      \&read_etc_resolv_conf, undef, 
	      \&update_etc_resolv_conf);

sub read_etc_timezone {
    my ($filename, $fd) = @_;

    my $timezone = <$fd>;

    chomp $timezone;

    return $timezone;
}

sub write_etc_timezone {
    my ($filename, $fh, $timezone) = @_;

    my $tzinfo = "/usr/share/zoneinfo/$timezone";

    raise_param_exc({ 'timezone' => "No such timezone" })
	if (! -f $tzinfo);

    ($timezone) = $timezone =~ m/^(.*)$/; # untaint

    print $fh "$timezone\n";

    unlink ("/etc/localtime");
    symlink ("/usr/share/zoneinfo/$timezone", "/etc/localtime");

}

register_file('timezone', "/etc/timezone", 
	      \&read_etc_timezone, 
	      \&write_etc_timezone);

sub read_active_workers {
    my ($filename, $fh) = @_;

    return [] if !$fh;

    my $res = []; 
    while (defined (my $line = <$fh>)) {
	if ($line =~ m/^(\S+)\s(0|1)(\s([0-9A-Za-z]{8})(\s(\s*\S.*))?)?$/) {
	    my $upid = $1;
	    my $saved = $2;
	    my $endtime = $4;
	    my $status = $6;
	    if ((my $task = PVE::Tools::upid_decode($upid, 1))) {
		$task->{upid} = $upid;
		$task->{saved} = $saved;
		$task->{endtime} = hex($endtime) if $endtime;
		$task->{status} = $status if $status;
		push @$res, $task;
	    }
	} else {
	    warn "unable to parse line: $line";
	}
    }

    return $res;

}

sub write_active_workers {
    my ($filename, $fh, $tasklist) = @_;

    my $raw = '';
    foreach my $task (@$tasklist) {
	my $upid = $task->{upid};
	my $saved = $task->{saved} ? 1 : 0;
	if ($task->{endtime}) {
	    if ($task->{status}) {
		$raw .= sprintf("$upid $saved %08X $task->{status}\n", $task->{endtime});
	    } else {
		$raw .= sprintf("$upid $saved %08X\n", $task->{endtime});
	    }
	} else {
	    $raw .= "$upid $saved\n";
	}
    }

    PVE::Tools::safe_print($filename, $fh, $raw) if $raw;
}

register_file('active', "/var/log/pve/tasks/active", 
	      \&read_active_workers,
	      \&write_active_workers);


my $bond_modes = { 'balance-rr' => 0,
		   'active-backup' => 1,
		   'balance-xor' => 2,
		   'broadcast' => 3,
		   '802.3ad' => 4,
		   'balance-tlb' => 5,
		   'balance-alb' => 6,
	       };

#sub get_bond_modes {
#    return $bond_modes;
#}

sub read_etc_network_interfaces {
    my ($filename, $fh) = @_;

    my $ifaces = {};

    my $line;

    if (my $fd2 = IO::File->new("/proc/net/dev", "r")) {
	while (defined ($line = <$fd2>)) {
	    if ($line =~ m/^\s*(eth\d+):.*/) {
		$ifaces->{$1}->{exists} = 1;
	    }
	}
	close($fd2);
    }

    # we try to keep order inside the file
    my $priority = 2; # 1 is reserved for lo 

    # always add the vmbr0 bridge device
    $ifaces->{vmbr0}->{exists} = 1;

    if (my $fd2 = IO::File->new("/proc/net/if_inet6", "r")) {
	while (defined ($line = <$fd2>)) {
	    if ($line =~ m/^[a-f0-9]{32}\s+[a-f0-9]{2}\s+[a-f0-9]{2}\s+[a-f0-9]{2}\s+[a-f0-9]{2}\s+(lo|eth\d+|vmbr\d+|bond\d+)$/) {
		$ifaces->{$1}->{active} = 1;
	    }
	}
	close ($fd2);
    }

    my $gateway = 0;

    while (defined ($line = <$fh>)) {
	chomp ($line);
	next if $line =~ m/^#/;
 
	if ($line =~ m/^auto\s+(.*)$/) {
	    my @aa = split (/\s+/, $1);

	    foreach my $a (@aa) {
		$ifaces->{$a}->{autostart} = 1;
	    }

	} elsif ($line =~ m/^iface\s+(\S+)\s+inet\s+(\S+)\s*$/) {
	    my $i = $1;
	    $ifaces->{$i}->{method} = $2;
	    $ifaces->{$i}->{priority} = $priority++;

	    my $d = $ifaces->{$i};
	    while (defined ($line = <$fh>)) {
		if ($line =~ m/^\s*#(.*)\s*$/) {
		    # NOTE: we use 'comments' instead of 'comment' to 
		    # avoid automatic utf8 conversion
		    $d->{comments} = '' if !$d->{comments};
		    $d->{comments} .= "$1\n";
		} elsif ($line =~ m/^\s+((\S+)\s+(.+))$/) {
		    my $option = $1;
		    my ($id, $value) = ($2, $3);
		    if (($id eq 'address') || ($id eq 'netmask') || ($id eq 'broadcast')) {
			$d->{$id} = $value;
		    } elsif ($id eq 'gateway') {
			$d->{$id} = $value;
			$gateway = 1;
		    } elsif ($id eq 'slaves' || $id eq 'bridge_ports') {
			my $devs = {};
			foreach my $p (split (/\s+/, $value)) {
			    next if $p eq 'none';
			    $devs->{$p} = 1;
			}
			my $str = join (' ', sort keys %{$devs});
			$d->{$id} = $str || '';
		    } elsif ($id eq 'bridge_stp') {
			if ($value =~ m/^\s*(on|yes)\s*$/i) {
			    $d->{$id} = 'on';
			} else {
			    $d->{$id} = 'off';
			}
		    } elsif ($id eq 'bridge_fd') {
			$d->{$id} = $value;
		    } elsif ($id eq 'bond_miimon') {
			$d->{$id} = $value;
		    } elsif ($id eq 'bond_mode') {
			# always use names
			foreach my $bm (keys %$bond_modes) {
			    my $id = $bond_modes->{$bm};
			    if ($id eq $value) {
				$value = $bm;
				last;
			    }
			}
			$d->{$id} = $value;
		    } else {
			push @{$d->{options}}, $option;
		    }
		} else {
		    last;
		}
	    }
	}
    }


    if (!$gateway) {
	$ifaces->{vmbr0}->{gateway} = '';
    }

    if (!$ifaces->{lo}) {
	$ifaces->{lo}->{priority} = 1;
	$ifaces->{lo}->{method} = 'loopback';
	$ifaces->{lo}->{type} = 'loopback';
	$ifaces->{lo}->{autostart} = 1;
    }

    foreach my $iface (keys %$ifaces) {
	my $d = $ifaces->{$iface};
	if ($iface =~ m/^bond\d+$/) {
	    $d->{type} = 'bond';
	} elsif ($iface =~ m/^vmbr\d+$/) {
	    $d->{type} = 'bridge';
	    if (!defined ($d->{bridge_fd})) {
		$d->{bridge_fd} = 0;
	    }
	    if (!defined ($d->{bridge_stp})) {
		$d->{bridge_stp} = 'off';
	    }
	} elsif ($iface =~ m/^(\S+):\d+$/) {
	    $d->{type} = 'alias';
	    if (defined ($ifaces->{$1})) {
		$d->{exists} = $ifaces->{$1}->{exists};
	    } else {
		$ifaces->{$1}->{exists} = 0;
		$d->{exists} = 0;
	    }
	} elsif ($iface =~ m/^eth\d+$/) {
	    $d->{type} = 'eth';
	} elsif ($iface =~ m/^lo$/) {
	    $d->{type} = 'loopback';
	} else {
	    $d->{type} = 'unknown';
	}

	$d->{method} = 'manual' if !$d->{method};
    }

    return $ifaces;
}

sub __interface_to_string {
    my ($iface, $d) = @_;

    return '' if !($d && $d->{method});

    my $raw = '';

    if ($d->{autostart}) {
	$raw .= "auto $iface\n";
    }
    $raw .= "iface $iface inet $d->{method}\n";
    $raw .= "\taddress  $d->{address}\n" if $d->{address};
    $raw .= "\tnetmask  $d->{netmask}\n" if $d->{netmask};
    $raw .= "\tgateway  $d->{gateway}\n" if $d->{gateway};
    $raw .= "\tbroadcast  $d->{broadcast}\n" if $d->{broadcast};

    if ($d->{bridge_ports} || ($iface =~ m/^vmbr\d+$/)) {
	my $ports = $d->{bridge_ports} || 'none';
	$raw .= "\tbridge_ports $ports\n";
    }

    if ($d->{bridge_stp} || ($iface =~ m/^vmbr\d+$/)) {
	my $v = $d->{bridge_stp};
	$v = defined ($v) ? $v : 'off';
	$raw .= "\tbridge_stp $v\n";
    }

    if (defined ($d->{bridge_fd}) || ($iface =~ m/^vmbr\d+$/)) {
	my $v = $d->{bridge_fd};
	$v = defined ($v) ? $v : 0;
	$raw .= "\tbridge_fd $v\n";
    }

    if ($d->{slaves} || ($iface =~ m/^bond\d+$/)) {
	my $slaves = $d->{slaves} || 'none';
	$raw .= "\tslaves $slaves\n";
    }

    if (defined ($d->{'bond_miimon'}) || ($iface =~ m/^bond\d+$/)) {
	my $v = $d->{'bond_miimon'};
	$v = defined ($v) ? $v : 100;
	$raw .= "\tbond_miimon $v\n";
    }

    if (defined ($d->{'bond_mode'}) || ($iface =~ m/^bond\d+$/)) {
	my $v = $d->{'bond_mode'};
	$v = defined ($v) ? $v : 'balance-rr';
	$raw .= "\tbond_mode $v\n";
    }

    foreach my $option (@{$d->{options}}) {
	$raw .= "\t$option\n";
    }

    # add comments
    my $comments = $d->{comments} || '';
    foreach my $cl (split(/\n/, $comments)) {
	$raw .= "#$cl\n";
    }

    $raw .= "\n";

    return $raw;
}

sub write_etc_network_interfaces {
    my ($filename, $fh, $ifaces) = @_;

    my $raw = "# network interface settings\n";

    my $printed = {};

    my $if_type_hash = {
	loopback => 10,
	eth => 20,
	bond => 30,
	bridge => 40,
    };

    my $lookup_type_prio = sub {
	my $iface = shift;

	my $alias = 0;
	if ($iface =~ m/^(\S+):\d+$/) {
	    $iface = $1;
	    $alias = 1;
	}

	my $pri;
	if ($iface eq 'lo') {
	    $pri = $if_type_hash->{loopback};
	} elsif ($iface =~ m/^eth\d+$/) {
	    $pri = $if_type_hash->{eth} + $alias;
	} elsif ($iface =~ m/^bond\d+$/) {
	    $pri = $if_type_hash->{bond} + $alias;
	} elsif ($iface =~ m/^vmbr\d+$/) {
	    $pri = $if_type_hash->{bridge} + $alias;
	}

	return $pri || ($if_type_hash->{unknown} + $alias);
    };

    foreach my $iface (sort {
	my $ref1 = $ifaces->{$a};
	my $ref2 = $ifaces->{$b};
	my $p1 = &$lookup_type_prio($a);
	my $p2 = &$lookup_type_prio($b);

	return $p1 <=> $p2 if $p1 != $p2;

	$p1 = $ref1->{priority} || 100000;
	$p2 = $ref2->{priority} || 100000;

	return $p1 <=> $p2 if $p1 != $p2;

	return $a cmp $b;
		       } keys %$ifaces) {

	my $d = $ifaces->{$iface};

	next if $printed->{$iface};

	$printed->{$iface} = 1;
	$raw .= __interface_to_string($iface, $d);
    }
    
    PVE::Tools::safe_print($filename, $fh, $raw);
}

register_file('interfaces', "/etc/network/interfaces",
	      \&read_etc_network_interfaces,
	      \&write_etc_network_interfaces);

1;
