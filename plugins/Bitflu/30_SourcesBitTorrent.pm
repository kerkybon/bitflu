package Bitflu::SourcesBitTorrent;

################################################################################################
#
# This file is part of 'Bitflu' - (C) 2006-2009 Adrian Ulrich
#
# Released under the terms of The "Artistic License 2.0".
# http://www.perlfoundation.org/legal/licenses/artistic-2_0.txt
#
#
# This plugin implements simple BitTorrent tracker (client!) support.
# Note: This plugin does mess with the internals of Bitflu::DownloadBitTorrent !
#       Maybe some kind person offers to rewrite this code mess? :-)
#
################################################################################################

use strict;
use List::Util;
use constant _BITFLU_APIVERSION   => 20081220;
use constant TORRENT_RUN          => 3;   # How often shall we check for work
use constant TRACKER_TIMEOUT      => 35;  # How long do we wait for the tracker to drop the connection
use constant TRACKER_MIN_INTERVAL => 360; # Minimal interval value for Tracker replys
use constant TRACKER_SKEW         => 20;  # Avoid storm at startup

use constant SBT_NOTHING_SENT_YET => 0;   # => 'started' will be the next event sent to the tracker
use constant SBT_SENT_START       => 1;   # => 'completed' will be the next event if we completed just now
use constant SBT_SENT_COMPLETE    => 2;   # => download is done, do not send any events to tracker

use constant PERTORRENT_TRACKERBL => '_trackerbl';

################################################################################################
# Register this plugin
sub register {
	my($class, $mainclass) = @_;
	my $self = { super => $mainclass, bittorrent => undef, p_tcp=>undef, p_udp=>undef,
	             secret => int(rand(0xFFFFFF)), next_torrentrun => 0, torrents => {} };
	bless($self,$class);
	
	my $bindto = ($self->{super}->Configuration->GetValue('torrent_bind') || 0); # May be null
	my $cproto = { torrent_trackerblacklist=>'', torrent_udptracker_port=>6689 };
	foreach my $k (keys(%$cproto)) {
		my $cval = $mainclass->Configuration->GetValue($k);
		unless(defined($cval)) {
			$mainclass->Configuration->SetValue($k, $cproto->{$k});
		}
	}
	$mainclass->Configuration->RuntimeLockValue('torrent_udptracker_port');
	
	
	$self->{p_tcp} = Bitflu::SourcesBitTorrent::TCP->new(_super=>$self, Bind=>$bindto);
	$self->{p_udp} = Bitflu::SourcesBitTorrent::UDP->new(_super=>$self, Bind=>$bindto,
	                                                         Port=>$mainclass->Configuration->GetValue('torrent_udptracker_port'));
	
	$mainclass->AddRunner($self) or $self->panic("Unable to add runner");
	
	return $self;
}

################################################################################################
# Init plugin
sub init {
	my($self) = @_;
	my $hookit = undef;
	
	# Search DownloadBitTorrent hook:
	foreach my $rx (@{$self->{super}->{_Runners}}) {
		if($rx->{target} =~ /^Bitflu::DownloadBitTorrent=/) {
			$hookit = $rx->{target};
		}
	}
	if(defined($hookit)) {
		$self->debug("Using '$hookit' to communicate with BitTorrent plugin.");
		$self->{bittorrent} = $hookit;
		$self->{bittorrent}->{super}->Admin->RegisterCommand('tracker'  , $self, '_Command_Tracker', 'Displays information about tracker',
		   [ [undef, "Usage: tracker queue_id [show|blacklist regexp]"], [undef, "This command displays detailed information about BitTorrent trackers"] ]);
		return 1;
	}
	else {
		$self->panic("Unable to find BitTorrent plugin!");
	}
	die "NOTREACHED";
}



################################################################################################
# Mainloop
sub run {
	my($self) = @_;
	
	my $NOW = $self->{super}->Network->GetTime;     # Cache current time
	$self->{super}->Network->Run($self->{p_tcp});   # Trigger tcp activity
	$self->{super}->Network->Run($self->{p_udp});   # Trigger udp activity
	
	return 1 if ($NOW < $self->{next_torrentrun});  # No need to work each few seconds
	$self->{next_torrentrun} = $NOW + TORRENT_RUN;
	
	foreach my $loading_torrent ($self->{bittorrent}->Torrent->GetTorrents) {
		my $this_torrent = $self->{bittorrent}->Torrent->GetTorrent($loading_torrent);
		
		if($this_torrent->IsPaused) {
			# Skip paused torrent
		}
		elsif(!defined($self->{torrents}->{$loading_torrent})) {
			# Cache data for new torrent
			my $raw_data = $this_torrent->Storage->GetSetting('_torrent') or next; # No torrent, no trackers anyway
			my $decoded  = Bitflu::DownloadBitTorrent::Bencoding::decode($raw_data);
			my $trackers = [];
			
			if(exists($decoded->{'announce-list'}) && ref($decoded->{'announce-list'}) eq "ARRAY") {
				$trackers = $decoded->{'announce-list'};
			}
			else {
				push(@$trackers, [$decoded->{announce}]);
			}
			
			$self->{torrents}->{$loading_torrent} = { cttlist=>[], cstlist=>[], info_hash=>$loading_torrent,
			                                          skip_until=>$NOW+int(rand(TRACKER_SKEW)), last_query=>0,
			                                          tracker=>'', rowfail=>0,
			                                          stamp=>$NOW, trackers=>$trackers, waiting=>0, timeout_at=>0 };
		}
		else {
			# Just refresh the stamp
			$self->{torrents}->{$loading_torrent}->{stamp} = $NOW;
		}
	}
	
	
	# Loop for cached torrents
	foreach my $this_torrent (List::Util::shuffle(keys(%{$self->{torrents}}))) {
		my $obj = $self->{torrents}->{$this_torrent};
		
		if($obj->{stamp} != $NOW) {
			# Whoops, this torrent vanished from main plugin -> drop it
			$self->MarkTrackerAsBroken($obj); # fail and stop current activity (if any)
			delete($self->{torrents}->{$this_torrent});
			next;
		}
		else {
			if($obj->{waiting}) { # Tracker has been contacted
				if($obj->{timeout_at} < $NOW) {
					$self->info("$this_torrent: tracker '$obj->{tracker}' timed out");
					$self->MarkTrackerAsBroken($obj, Softfail=>1);
					$obj->{skip_until} = $NOW + int(rand(TRACKER_SKEW)); # fast retry
				}
			}
			elsif($obj->{skip_until} > $NOW) {
				# Nothing to do.
			}
			else {
				$self->QueryTracker($obj);
			}
		}
	}
	
	return 1;
}


################################################################################################
# Build trackerlist (if needed) and contact a tracker
sub QueryTracker {
	my($self, $obj) = @_;
	
	my $NOW            = $self->{bittorrent}->{super}->Network->GetTime;
	my $sha1           = $obj->{info_hash};
	$obj->{skip_until} = $NOW + TRACKER_MIN_INTERVAL; # Do not hammer the tracker if it closes the connection quickly
	
	# This construct is used to select new trackers
	if(int(@{$obj->{cttlist}}) == 0) {
		# Fillup
		$obj->{cttlist} = deep_copy($obj->{trackers});
	}
	if(int(@{$obj->{cstlist}}) == 0) {
		my @rnd = (List::Util::shuffle(@{shift(@{$obj->{cttlist}})}));
		my @fixed = ();
		
		foreach my $this_tracker (@rnd) {
			my($proto,$host,$port,$base) = $self->ParseTrackerUri({tracker=>$this_tracker});
			if($proto eq 'http') { push(@fixed, "udp://$host:$port/$base#bitflu-autoudp") }
			push(@fixed, $this_tracker);
		}
		print Data::Dumper::Dumper(\@fixed);
		$obj->{cstlist} = \@fixed;
	}
	unless($obj->{tracker}) {
		# No selected tracker: get a newone
		$obj->{tracker} = ( shift(@{$obj->{cstlist}}) || '' );  # Grab next tracker
		$self->BlessTracker($obj);                              # Reset fails
	}
	
	$self->ContactCurrentTracker($obj);
}

################################################################################################
# Concact tracker
sub ContactCurrentTracker {
	my($self, $obj) = @_;
	
	my $NOW       = $self->{bittorrent}->{super}->Network->GetTime;
	my $blacklist = $self->GetTrackerBlacklist($obj);
	my $sha1      = $obj->{info_hash} or $self->panic("No info hash");
	my $tracker   = $obj->{tracker};
	my ($proto)   = $self->ParseTrackerUri($obj);
	
	if(length($tracker) == 0) {
		$self->debug("$sha1: has currently no tracker");
	}
	elsif(length($blacklist) && $tracker =~ /$blacklist/i) {
		$self->info("$sha1: Skipping blacklisted tracker '$tracker'");
		$self->MarkTrackerAsBroken($obj);
		$obj->{skip_until} = $NOW + int(rand(TRACKER_SKEW));
	}
	else {
		# -> Not blacklisted
		if($proto eq 'http') {
			$obj->{timeout_at} = $NOW + TRACKER_TIMEOUT;       # Set response timeout
			$obj->{last_query} = $NOW;                         # Remember last querytime
			$obj->{waiting}    = $self->{p_tcp}->Start($obj);  # Start request via tcp/http
		}
		elsif($proto eq 'udp') {
			$obj->{timeout_at} = $NOW + TRACKER_TIMEOUT;       # Set response timeout
			$obj->{last_query} = $NOW;                         # Remember last querytime
			$obj->{waiting}    = $self->{p_udp}->Start($obj);  # Start request via udp
		}
		else {
			$self->info("$sha1: Protocol of tracker '$tracker' is not supported.");
			$self->MarkTrackerAsBroken($obj);
		}
	}
}

################################################################################################
# Advance to next request and stop in-flight transactions
sub MarkTrackerAsBroken {
	my($self,$obj,%args) = @_;
	
	my $softfail = ($args{Softfail} ? 1 : 0);
	
	$self->info("MarkTrackerAsBroken($self,$obj) :: $obj->{waiting} >> $softfail");
	
	if($obj->{waiting}) {
		$obj->{waiting}->Stop($obj);
		$obj->{waiting} = 0;
	}
	
	if(++$obj->{rowfail} >= 3 or !$softfail) {
		$self->info("Marking current tracker as dead ($obj->{rowfail} : $softfail)");
		$obj->{tracker} = '';
		# rowfail will be reseted while selecting a new tracker
	}
}

################################################################################################
# Mark current tracker as good
sub BlessTracker {
	my($self,$obj) = @_;
	$self->info("Blessing $obj->{tracker}");
	$obj->{rowfail} = 0;
}

################################################################################################
# Returns the trackerblacklist for given object
sub GetTrackerBlacklist {
	my($self, $obj) = @_;
	my $tbl  = '';
	my $sha1 = $obj->{info_hash} or $self->panic("$obj has no info_hash key!");
	
	if((my $torrent = $self->{bittorrent}->Torrent->GetTorrent($sha1))) {
		$tbl = $torrent->Storage->GetSetting(PERTORRENT_TRACKERBL);
	}
	if(!defined($tbl) || length($tbl) == 0) {
		$tbl = $self->{bittorrent}->{super}->Configuration->GetValue('torrent_trackerblacklist');
	}
	return $tbl;
}

################################################################################################
# Parse an uri
sub ParseTrackerUri {
	my($self, $obj) = @_;
	my ($proto,$host,$port,$base) = $obj->{tracker} =~ /^([^:]+):\/\/([^\/:]+):?(\d*)\/(.*)$/i;
	$proto  = lc($proto);
	$host   = lc($host);
	$port ||= 80;
	$base ||= '';
	
	$self->debug("ParseTrackerUri($obj->{tracker}) -> proto=$proto, host=$host, port=$port, base=$base");
	
	return($proto,$host,$port,$base);
}

################################################################################################
# Returns current tracker event
sub GetTrackerEvent {
	my($self,$obj) = @_;
	my $sha1     = $obj->{info_hash} or $self->panic("No info_hash?");
	my $tobj     = $self->{bittorrent}->Torrent->GetTorrent($sha1);
	
	my $current_setting = int($tobj->Storage->GetSetting('_sbt_trackerstat') || SBT_NOTHING_SENT_YET);
	
	if($current_setting == SBT_NOTHING_SENT_YET) {
		return 'started';
	}
	elsif($current_setting == SBT_SENT_START && $tobj->IsComplete) {
		return 'completed';
	}
	else {
		return '';
	}
}

################################################################################################
# Go to next tracker event
sub AdvanceTrackerEvent {
	my($self,$obj) = @_;
	my $sha1            = $obj->{info_hash} or $self->panic("No info_hash?");
	my $tobj            = $self->{bittorrent}->Torrent->GetTorrent($sha1);
	my $current_setting = $self->GetTrackerEvent($obj);
	my $nsetting        = 0;
	
	if($current_setting eq 'started') {
		$nsetting = SBT_SENT_START;
	}
	elsif($current_setting eq 'completed') {
		$nsetting = SBT_SENT_COMPLETE;
	}
	
	$tobj->Storage->SetSetting('_sbt_trackerstat', $nsetting) if $nsetting != 0;
}

########################################################################
# Decodes Compact IP-Chunks
sub DecodeCompactIp {
	my($self, $compact_list) = @_;
	my @peers = ();
		for(my $i=0;$i<length($compact_list);$i+=6) {
			my $chunk = substr($compact_list, $i, 6);
			my($a,$b,$c,$d,$port) = unpack("CCCCn", $chunk);
			my $ip = "$a.$b.$c.$d";
			push(@peers, {ip=>$ip, port=>$port, peer_id=>""});
		}
	return @peers;
}



################################################################################################
# CLI Command
sub _Command_Tracker {
	my($self,@args) = @_;
	
	my $sha1   = $args[0];
	my $cmd    = $args[1];
	my $value  = $args[2];
	my @MSG    = ();
	my @SCRAP  = ();
	my $NOEXEC = '';
	
	if(defined($sha1)) {
		if(!defined($cmd) or $cmd eq "show") {
			if(exists($self->{torrents}->{$sha1})) {
				my $obj = $self->{torrents}->{$sha1};
				push(@MSG, [3, "Trackers for $sha1"]);
				push(@MSG, [undef, "Next Query           : ".localtime($obj->{skip_until})]);
				push(@MSG, [undef, "Last Query           : ".($obj->{last_query} ? localtime($obj->{last_query}) : 'Never contacted') ]);
				push(@MSG, [($self->{torrents}->{$sha1}->{waiting}?2:1), "Waiting for response : ".($obj->{waiting}?"Yes":"No")]);
				push(@MSG, [undef, "Current Tracker      : $obj->{tracker}"]);
				push(@MSG, [undef, "Fails                : $obj->{rowfail}"]);
				my $allt = '';
				foreach my $aref (@{$self->{torrents}->{$sha1}->{trackers}}) {
					$allt .= join(';',@$aref)." ";
				}
				push(@MSG, [undef, "All Trackers         : $allt"]);
				push(@MSG, [undef, "Tracker Blacklist    : ".$self->GetTrackerBlacklist($obj)]);
			}
			else {
				push(@SCRAP, $sha1);
				$NOEXEC .= "$sha1: No such torrent";
			}
		}
		elsif($cmd eq "blacklist") {
			if(my $torrent = $self->{bittorrent}->Torrent->GetTorrent($sha1)) {
				$torrent->Storage->SetSetting(PERTORRENT_TRACKERBL, $value);
				push(@MSG, [1, "$sha1: Tracker blacklist set to '$value'"]);
			}
			else {
				push(@SCRAP, $sha1);
				$NOEXEC .= "$sha1: No such torrent";
			}
		}
		else {
			push(@MSG, [2, "Unknown subcommand '$cmd'"]);
		}
	}
	else {
		$NOEXEC .= "Usage error, type 'help tracker' for more information";
	}
	return({MSG=>\@MSG, SCRAP=>\@SCRAP, NOEXEC=>$NOEXEC});
}





################################################################################################
# Stolen from http://www.stonehenge.com/merlyn/UnixReview/col30.html
sub deep_copy {
	my $this = shift;
	if (not ref $this) {
		$this;
	} elsif (ref $this eq "ARRAY") {
		[map deep_copy($_), @$this];
	} elsif (ref $this eq "HASH") {
		+{map { $_ => deep_copy($this->{$_}) } keys %$this};
	} else { die "what type is $_?" }
}


sub debug { my($self, $msg) = @_; $self->{super}->debug("Tracker : ".$msg); }
sub info  { my($self, $msg) = @_; $self->{super}->info("Tracker : ".$msg);  }
sub warn  { my($self, $msg) = @_; $self->{super}->warn("Tracker : ".$msg);  }
sub panic { my($self, $msg) = @_; $self->{super}->panic("Tracker : ".$msg); }

1;




################################################################################################



package Bitflu::SourcesBitTorrent::TCP;
	
	################################################################################################
	# Returns a new TCP-Object
	sub new {
		my($class, %args) = @_;
		my $self = { _super=>$args{_super}, super=>$args{_super}->{super}, net=>{bind=>$args{Bind}, port=>0, sock=>undef },
		             sockmap=>{} };
		bless($self,$class);
		
		my $sock = $self->{super}->Network->NewTcpListen(ID=>$self, Bind=>$self->{net}->{bind}, Port=>$self->{net}->{port},
		                                                 MaxPeers=>8, Callbacks => { Data  =>'_Network_Data',
		                                                                             Close =>'_Network_Close' } );
		$self->{net}->{sock} = $sock;
		return $self;
	}
	
	################################################################################################
	# Starts a new request
	sub Start {
		my($self,$obj) = @_;
		
		my($proto,$host,$port,$base) = $self->{_super}->ParseTrackerUri($obj);
		
		my $sha1     = $obj->{info_hash} or $self->panic("No info_hash?");
		my $stats    = $self->{super}->Queue->GetStats($sha1);
		my $event    = $self->{_super}->GetTrackerEvent($obj);
		my $nextchar = "?";
		   $nextchar = "&" if ($base =~ /\?/);
		
		# Create good $key and $peer_id length
		my $key      = $self->_UriEscape(pack("H40",unpack("H40",$self->{_super}->{secret}.("x" x 20))));
		my $peer_id  = $self->_UriEscape(pack("H40",unpack("H40",$self->{_super}->{bittorrent}->{CurrentPeerId})));
		
		# Assemble HTTP-Request
		my $q  = "GET /".$base.$nextchar."info_hash=".$self->_UriEscape(pack("H40",$obj->{info_hash}));
		   $q .= "&peer_id=".$peer_id;
		   $q .= "&port=".int($self->{super}->Configuration->GetValue('torrent_port'));
		   $q .= "&uploaded=".int($stats->{uploaded_bytes});
		   $q .= "&downloaded=".int($stats->{done_bytes});
		   $q .= "&left=".int($stats->{total_bytes}-$stats->{done_bytes});
		   $q .= "&key=".$key;
		   $q .= "&event=$event";
		   $q .= "&compact=1";
		   $q .= " HTTP/1.0\r\n";
		   $q .= "User-Agent: Bitflu ".$self->{super}->GetVersionString."\r\n";
		   $q .= "Host: $host:$port\r\n\r\n";
		
		$self->info("$sha1: Contacting $proto://$host:$port/$base ...");
		
		my $tsock = $self->{super}->Network->NewTcpConnection(ID=>$self, Port=>$port, Hostname=>$host, Timeout=>5);
		if($tsock) {
			$self->{super}->Network->WriteDataNow($tsock, $q) or $self->panic("Unable to write data to $tsock !");
			$self->{sockmap}->{$tsock} = { obj=>$obj, socket=>$tsock, buffer=>'' };
		}
		else {
			# Request will timeout -> tracker marked will be marked as broken
			$self->warn("Failed to create a new connection to $host:$port : $!");
		}
		
		return $self;
	}
	
	################################################################################################
	# Append data to buffer (if still active)
	sub _Network_Data {
		my($self,$sock,$buffref,$blen) = @_;
		if(exists($self->{sockmap}->{$sock})) {
			$self->{sockmap}->{$sock}->{buffer} .= ${$buffref}; # append data if socket still active
		}
	}
	
	################################################################################################
	# Connection finished: Parse data and add new peers
	sub _Network_Close {
		my($self,$sock) = @_;
		if(exists($self->{sockmap}->{$sock})) {
			my $smap    = $self->{sockmap}->{$sock};
			my $buffer  = $smap->{buffer};
			my $obj     = $smap->{obj}                     or $self->panic("Missing object!");
			my $sha1    = $obj->{info_hash}                or $self->panic("No info_hash?");
			my $bobj    = $self->{_super}->{bittorrent}    or $self->panic("No BT-Object?");
			my @nnodes  = ();       # NewNodes
			my $hdr_len = 0;        # HeaderLength
			my $decoded = undef;    # Decoded data
			my $failed  = 0;        # Did the tracker fail?
			
			
			# Ditch existing HTTP-Header
			foreach my $line (split(/\n/,$buffer)) {
				$hdr_len += length($line)+1; # 1=\n
				last if $line eq "\r";       # Found end of HTTP-Header (\r\n)
			}
			
			if(length($buffer) > $hdr_len) {
				$buffer = substr($buffer,$hdr_len); # Throws the http header away
				$decoded = Bitflu::DownloadBitTorrent::Bencoding::decode($buffer);
			}
			
			if(ref($decoded) ne "HASH" or !exists($decoded->{peers})) {
				$self->info("$sha1: received invalid response from tracker.");
				$failed = 1;
			}
			elsif(ref($decoded->{peers}) eq "ARRAY") {
				foreach my $cref (@{$decoded->{peers}}) {
					push(@nnodes , { ip=> $cref->{ip}, port=> $cref->{port}, peer_id=> $cref->{'peer id'} } );
				}
			}
			else {
				@nnodes = $self->{_super}->DecodeCompactIp($decoded->{peers});
			}
			
			# Calculate new Skiptime
			my $new_skip = $self->{super}->Network->GetTime + (abs(int($decoded->{interval}||0)));
			my $old_skip = $obj->{skip_until};
			$obj->{skip_until} = ( $new_skip > $old_skip ? $new_skip : $old_skip ); # Set new skip_until time
			$obj->{waiting}    = 0;                                                 # No open transaction
			delete($self->{sockmap}->{$sock}) or $self->panic;                      # Mark socket as down
			
			if($bobj->Torrent->ExistsTorrent($sha1) && !$failed) {
				# Torrent does still exist: add nodes
				$bobj->Torrent->GetTorrent($sha1)->AddNewPeers(List::Util::shuffle(@nnodes));
				$self->{_super}->AdvanceTrackerEvent($obj);
				$self->{_super}->BlessTracker($obj);
				$self->info("$sha1: tracker returned ".int(@nnodes)." peers");
			}
			elsif($failed) {
				$self->{_super}->MarkTrackerAsBroken($obj, Softfail=>1)
			}
			
		}
	}
	
	################################################################################################
	# Aborts in-flight transactions
	sub Stop {
		my($self,$obj) = @_;
		
		foreach my $snam (keys(%{$self->{sockmap}})) {
			if($self->{sockmap}->{$snam}->{obj} eq $obj) {
				my $socket = $self->{sockmap}->{$snam}->{socket};
				$self->_Network_Close($socket);                        # cleans sockmap
				$self->{super}->Network->RemoveSocket($self, $socket); # drop connection
			}
		}
		
	}
	
	################################################################################################
	# Primitive Escaping
	sub _UriEscape {
		my($self,$string) = @_;
		my $esc = undef;
		foreach my $c (split(//,$string)) {
			$esc .= sprintf("%%%02X",ord($c));
		}
		return $esc;
	}
	
	sub debug { my($self, $msg) = @_; $self->{_super}->debug($msg); }
	sub info  { my($self, $msg) = @_; $self->{_super}->info($msg);  }
	sub warn  { my($self, $msg) = @_; $self->{_super}->warn($msg);  }
	sub panic { my($self, $msg) = @_; $self->{_super}->panic($msg); }

1;





package Bitflu::SourcesBitTorrent::UDP;
	use constant OP_CONNECT  => 0;
	use constant OP_ANNOUNCE => 1;
	
	
	################################################################################################
	# Creates a new UDP object
	sub new {
		my($class, %args) = @_;
		my $self = { _super=>$args{_super}, super=>$args{_super}->{super}, net=>{bind=>$args{Bind}, port=>$args{Port},
		             sock=>undef }, tmap=>{} };
		bless($self,$class);
		
		my $sock = $self->{super}->Network->NewUdpListen(ID=>$self, Bind=>$self->{net}->{bind}, Port=>$self->{net}->{port},
		                                                            Callbacks => {  Data  =>'_Network_Data' } );
		$self->{net}->{sock} = $sock or $self->panic("Failed to bind to $self->{net}->{bind}:$self->{net}->{port}: $!");
		return $self;
	}
	
	################################################################################################
	# Send a connect() request to current tracker
	sub Start {
		my($self,$obj) = @_;
		my $sha1                     = $obj->{info_hash};                        # Info Hash
		my($proto,$host,$port,$base) = $self->{_super}->ParseTrackerUri($obj);   # Parsed Tracker URI
		my($ip)                      = $self->{super}->Tools->Resolve($host);    # Resolve IP of given host
		my $tid                      = 0;                                        # Transaction IP
		
		# Find a random transaction id
		# $tid will be 'something' if this loop ends.
		# This isn't such a big problem: we will just add wrong ips to
		# the a wrong peer (this will result in broken connections..)
		for(0..255){
			$tid = int(rand(0xFFFFFF));
			last if !exists($self->{tmap}->{$tid});
		}
		
		# Assemble TransactionMap
		$self->{tmap}->{$tid} = { obj => $obj, ip=>$ip, port=>$port };
		
		if($ip) {
			# IMPLEMENTATION NOTE:
			# We send a new OP_CONNECT message for each tracker request.
			# We *could* cache the connection_id for the next request but it
			# doesn't make much sense to me:
			#
			# - An OP_LOGIN reply doesn't stress the tracker
			#   Most likely it will just have to return md5($secret$peerip)
			# - The documentation doesn't tell us how long we CAN cache
			#   the reply (and caching it is just a suggestion)
			# - Bitflu doesn't detect IP-Changes (this invalidates the connection_id)
			# - ...etc...
			
			$self->info("$sha1: Sending udp-request to $host:$port");
			my $payload = pack("H16", "0000041727101980").pack("NN",OP_CONNECT,$tid);
			$self->{super}->Network->SendUdp($self->{net}->{sock}, ID=>$self, Ip=>$ip, Port=>$port, Data=>$payload);
		}
		return $self;
	}
	
	################################################################################################
	# Invalidate transaction of $obj
	sub Stop {
		my($self, $obj) = @_;
		foreach my $trans_id (keys(%{$self->{tmap}})) {
			my $t_obj = $self->{tmap}->{$trans_id}->{obj};
			if($t_obj eq $obj) {
				delete($self->{tmap}->{$trans_id});
				last;
			}
		}
	}
	
	################################################################################################
	# Handles incoming udp data
	sub _Network_Data {
		my($self,$sock,$buffref) = @_;
		
		my $buffer  = ${$buffref};
		my $bufflen = length($buffer);
		
		if($bufflen >= 16) {
			my($action,$trans_id,$con_id) = unpack("NNH16",$buffer);
			
			if(exists($self->{tmap}->{$trans_id})) {
				# -> Transaction id matches
				
				my $tx_obj = $self->{tmap}->{$trans_id};             # Transaction object
				my $obj    = $tx_obj->{obj};                         # Tracker object
				my $sha1   = $obj->{info_hash};                      # Current info_hash
				my $btobj  = $self->{_super}->{bittorrent};          # BitTorrent object
				my $exists = $btobj->Torrent->ExistsTorrent($sha1);  # Does the torrent still exist?
				
				if(!$exists) {
					# torrent vanished: ignore response
				}
				elsif($action == OP_CONNECT) {
					# -> Connect response received. send an announce request
					
					my $t_port  = int($self->{super}->Configuration->GetValue('torrent_port'));
					my $t_key   = $self->{_super}->{secret};
					my $t_pid   = $btobj->{CurrentPeerId};
					my $t_stats = $self->{super}->Queue->GetStats($sha1);
					my $t_estr  = $self->{_super}->GetTrackerEvent($obj);
					my $t_enum  = undef;
					$t_enum     = ($t_estr eq 'started' ? 2 : ($t_estr eq 'completed' ? 1 : 0 ) );
					
					my $pkt  = pack("H16NN",$con_id,OP_ANNOUNCE,$trans_id);                     # ConnectionId, Opcode, TransactionId
					   $pkt .= pack("H40",$sha1).$t_pid;                                        # info_hash, peer-id (always 20)
					   $pkt .= pack("H8N",0,$t_stats->{done_bytes});                            # Downloaded
					   $pkt .= pack("H8N",0,($t_stats->{total_bytes}-$t_stats->{done_bytes}));  # Bytes left
					   $pkt .= pack("H8N",0,$t_stats->{uploaded_bytes});                        # Uploaded data
					   $pkt .= pack("N",$t_enum);                                               # Event (fixme: always zero)
					   $pkt .= pack("NNN",0,$t_key,50);                                         # IP (0), Secret, NumWant(50)
					   $pkt .= pack("n",$t_port);                                               # Port used by BitTorrent
					
					$self->{super}->Network->SendUdp($self->{net}->{sock}, ID=>$self, Ip=>$tx_obj->{ip},
					                                                       Port=>$tx_obj->{port}, Data=>$pkt);
				}
				elsif($action == OP_ANNOUNCE && $bufflen >= 20) {
					# -> Announce request: parse received peers
					
					my(undef,undef,$interval,$leechers,$seeders) = unpack("NNNNN",$buffer);
					
					$self->{_super}->AdvanceTrackerEvent($obj);
					$self->{_super}->BlessTracker($obj);
					
					# Parse and add nodes
					my @iplist = $self->{_super}->DecodeCompactIp(substr($buffer,20));
					$btobj->Torrent->GetTorrent($sha1)->AddNewPeers(List::Util::shuffle(@iplist));
					
					my $new_skip = $self->{super}->Network->GetTime + (abs(int($interval||0)));
					my $old_skip = $obj->{skip_until};
					$obj->{skip_until} = ( $new_skip > $old_skip ? $new_skip : $old_skip ); # Set new skip_until time
					$obj->{waiting}    = 0;                                                 # No open transaction
					$self->Stop($obj);                                                      # Invalidate tmap
					
					$self->info("$sha1: Received ".int(@iplist)." nodes (stats: seeders=$seeders, leechers=$leechers)");
				}
				else {
					$self->info("Ignoring udp-packet with length=$bufflen, action=$action");
				}
			}
			else {
				$self->info("Received udp-packet with invalid transaction-id ($trans_id), dropping data");
			}
		}
	}
	
	sub debug { my($self, $msg) = @_; $self->{_super}->debug($msg); }
	sub info  { my($self, $msg) = @_; $self->{_super}->info($msg);  }
	sub warn  { my($self, $msg) = @_; $self->{_super}->warn($msg);  }
	sub panic { my($self, $msg) = @_; $self->{_super}->panic($msg); }
1;
