# Copyright (C) 2005-2015 Quentin Sculo <squentin@free.fr>
#
# This file is part of Gmusicbrowser.
# Gmusicbrowser is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3, as
# published by the Free Software Foundation

package Play_mpv;
use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP;
use Time::HiRes 'sleep';

use POSIX ':sys_wait_h';	#for WNOHANG in waitpid

#$SIG{CHLD} = 'IGNORE';  # to make sure there are no zombies #cause crash after displaying a file dialog and then runnning an external command with mandriva's gtk2
#$SIG{CHLD} = sub { while (waitpid(-1, WNOHANG)>0) {} };

my (@cmd_and_args,$ChildPID,$WatchTag,$WatchTag2,@pidToKill,$Kill9);
my $sockfh;
my (%supported,$mpv);
my $preparednext;
my $playcounter;
my $initseek;
my $watcher;

my $SOCK = $::HomeDir."gmb_mpv_sock";

$::PlayPacks{Play_mpv}=1; #register the package

sub init
{	undef %supported;
	$mpv= $::Options{mpv_cmd};
	if ($mpv && !-x $mpv && !(::first { -x $_ } map $_.::SLASH.$mpv,  split /:/, $ENV{PATH}))
	{	$mpv=undef;
	}
	$mpv ||= ::first { -x $_ } map $_.::SLASH.'mpv',  split /:/, $ENV{PATH};

	return unless $mpv;
	return bless {RG=>1,EQ=>1},__PACKAGE__;
}

sub supported_formats
{	return () unless $mpv;
	unless (keys %supported)
	{for (qx($mpv --ad=help))
	 {	if	(m/:mp3\s/)	{$supported{mp3}=undef}
		elsif	(m/:vorbis\s/)	{$supported{oga}=undef}
		elsif	(m/:mpc\d/)	{$supported{mpc}=undef}
		elsif	(m/:flac\s/)	{$supported{flac}=undef}
		elsif	(m/:wavpack\s/) {$supported{wv}=undef}
		elsif	(m/:ape\s/)	{$supported{ape}=undef}
		elsif	(m/:aac\s/)	{$supported{m4a}=undef}
	 }
	}
	return keys %supported;
}

sub send_cmd
{	return unless $sockfh;
	my @args=@_;
	#mpv docs say that it prefers UTF8, but if we force that files with non-ASCII filenames don't play
	my $cmd = JSON::PP->new->encode({command => [@args]});
	print $sockfh "$cmd\n";
	warn "MPVCMD: $cmd\n" if $::debug;
}

sub launch_mpv
{	$playcounter=0;
	@cmd_and_args=($mpv, '--input-unix-socket='.$SOCK, qw/--idle --no-video --no-input-terminal --really-quiet --gapless-audio=weak --softvol-max=100/);
	push @cmd_and_args,"--volume=".convertvolume($::Volume);
	push @cmd_and_args,"--af-add=".get_RG_opts() if $::Options{use_replaygain};
	push @cmd_and_args,"--af-add=\@EQ:equalizer=$::Options{equalizer}" if $::Options{use_equalizer};
	push @cmd_and_args,split / /,$::Options{mpvoptions} if $::Options{mpvoptions};
	warn "@cmd_and_args\n" if $::debug;
	$ChildPID=fork;
	if (!defined $ChildPID) { warn "gmusicbrowser_mpv : fork failed : $!\n"; ::ErrorPlay("Fork failed : $!"); return }
	elsif ($ChildPID==0) #child
	{	exec @cmd_and_args  or print STDERR "launch failed (@cmd_and_args)  : $!\n";
		POSIX::_exit(1);
	}
	#wait for mpv to establish socket as server
	for (0 .. 20)
	{	$sockfh = IO::Socket::UNIX->new(Peer => $SOCK, Type => SOCK_STREAM);
		last if $sockfh || (waitpid($ChildPID, WNOHANG) != 0);
		warn "gmusicbrowser_mpv: could not connect to socket; retrying\n" if $::debug;
		sleep 0.1;
	}
	unless ($sockfh)
	{	handle_error("failed to connect to socket (probably failed to launch mpv): $!");
		return;
	}
	$sockfh->autoflush(1);
	$sockfh->blocking(0);
	$WatchTag = Glib::IO->add_watch(fileno($sockfh),'hup',\&_eos_cb);
	$WatchTag2= Glib::IO->add_watch(fileno($sockfh),'in',\&_remotemsg);
	$watcher = {};
	::Watch($watcher,'NextSongs', \&append_next);
	send_cmd('observe_property', 1, 'playback-time');
	send_cmd('request_log_messages', 'error');
	return 1;
}

sub Play
{	my (undef,$file,$sec)=@_;
	launch_mpv() unless $ChildPID && $sockfh;
	$playcounter++;
	# gapless - check for non-user-initiated EOF
	return if $preparednext && $preparednext eq $file && $playcounter == 1;
	$initseek = $sec;
	send_cmd('loadfile',$file);
	warn "playing $file (pid=$ChildPID)\n" if $::Verbose;
}

sub append_next
{	send_cmd('playlist_clear');
	send_cmd('loadfile',$::NextFileToPlay,'append') if $::NextFileToPlay;
	$preparednext=$::NextFileToPlay;
}

sub _remotemsg
{	for my $line (<$sockfh>)
	{	my $msg= decode_json($line);
		warn "mpv raw-output: $line" if $::debug;
		if (my $error=$msg->{error})
		{	warn "mpv error: $error" unless $error eq 'success';
		}
		elsif (my $event=$msg->{event})
		{	if ($event eq 'property-change' && $msg->{name} eq 'playback-time' && defined $msg->{data})
			 { ::UpdateTime($msg->{data}) if $playcounter==1; }
			elsif ($event eq 'end-file')	{ handle_eof(); }
			elsif ($event eq 'file-loaded')	{ SkipTo(undef,$initseek) if $initseek; $initseek=undef; }
			elsif ($event eq 'log-message') { handle_error("[$msg->{prefix}] $msg->{text}") unless $msg->{text}=~m/^mjpeg: overread \d+/; }
		}
	}
	return 1;
}

sub handle_eof
{	# ignore EOF signal on user-initiated track change
	$playcounter--;
	::end_of_file() if $playcounter == 0;
}

sub handle_error
{	my $error=shift;
	Stop();
	::ErrorPlay($error,_("Command used :")."\n@cmd_and_args");
}

sub _eos_cb
{	my $error;
	if ($ChildPID && $ChildPID==waitpid($ChildPID, WNOHANG))
	{	$error=_"Check your audio settings" if $?;
	}
	while (waitpid(-1, WNOHANG)>0) {}	#reap dead children
	handle_error ($error or "mpv process closed unexpectedly.");
	return 1;
}

sub Pause
{	send_cmd('set', 'pause', 'yes');
}
sub Resume
{	send_cmd('set', 'pause', 'no');
}

sub SkipTo
{	::setlocale(::LC_NUMERIC, 'C');
	my $sec="$_[1]";
	::setlocale(::LC_NUMERIC, '');
	send_cmd('seek', $sec, 'absolute');
}


sub Stop
{	if ($WatchTag)
	{	Glib::Source->remove($WatchTag);
		Glib::Source->remove($WatchTag2);
		$WatchTag=$WatchTag2=undef;
	}
	if ($ChildPID)
	{	send_cmd('quit');
		Glib::Timeout->add( 100,\&_Kill_timeout ) unless @pidToKill;
		$Kill9=0;	#_Kill_timeout will first try INT, then KILL
		push @pidToKill,$ChildPID;
		undef $ChildPID;
	}
	if ($sockfh)
	{	shutdown($sockfh,2);
		close($sockfh);
		unlink $SOCK;
		undef $sockfh;
	}
	if ($watcher)
	{	::UnWatch($watcher,'NextSongs');
		undef $watcher;
	}
}
sub _Kill_timeout	#make sure old children are dead
{	while (waitpid(-1, WNOHANG)>0) {}	#reap dead children
	@pidToKill=grep kill(0,$_), @pidToKill; #checks to see which ones are still there
	if (@pidToKill)
	{	warn "Sending ".($Kill9 ? 'KILL' : 'INT')." signal to @pidToKill\n" if $::debug;
		if ($Kill9)	{kill KILL=>@pidToKill;}
		else		{kill INT=>@pidToKill;}
		$Kill9=1;	#use KILL if they are still there next time
	}
	return @pidToKill;	#removes the timeout if no more @pidToKill
}

sub AdvancedOptions
{	my $vbox=Gtk2::VBox->new(::FALSE, 2);
	my $sg1=Gtk2::SizeGroup->new('horizontal');
	my $opt=::NewPrefEntry('mpvoptions',_"mpv options :", sizeg1=>$sg1);
	$vbox->pack_start($_,::FALSE,::FALSE,2), for $opt;
	return $vbox;
}

# Volume functions
sub GetVolume	{$::Volume}
sub GetMute	{$::Mute}
sub SetVolume
{	shift;
	my $set=shift;
	if	($set eq 'mute')	{ $::Mute=$::Volume; $::Volume=0; }
	elsif	($set eq 'unmute')	{ $::Volume=$::Mute; $::Mute=0;   }
	elsif	($set=~m/^\+(\d+)$/)	{ $::Volume+=$1; }
	elsif	($set=~m/^-(\d+)$/)	{ $::Volume-=$1; }
	elsif	($set=~m/(\d+)/)	{ $::Volume =$1; }
	$::Volume=0   if $::Volume<0;
	$::Volume=100 if $::Volume>100;
	my $vol= convertvolume($::Volume);	#use a cubic volume scale
	send_cmd('set', 'volume', $vol);
	::HasChanged('Vol');
	$::Options{Volume}=$::Volume;
	$::Options{Volume_mute}=$::Mute;
}

sub convertvolume	#convert a linear volume to cubic volume scale
{	my $vol=$_[0];
	$vol= 100*($vol/100)**3;
	# will be sent to mpv as string, make sure it use a dot as decimal separator
	::setlocale(::LC_NUMERIC, 'C');
	$vol="$vol";
	::setlocale(::LC_NUMERIC, '');
	return $vol;
}

sub set_equalizer
{	my (undef,$val)=@_;
	send_cmd('af','add','@EQ:equalizer='.$val);
}

sub EQ_Get_Range
{	return (-12,12,'dB');
}
sub EQ_Get_Hz
{	my $i=$_[1];
	# mplayer and GST equalizers use the same bands, but they are indicated differently
	# mplayer docs list band center frequences, GST reports band start freqs. Using GST values here for consistency
	my @bands=(qw/29Hz 59Hz 119Hz 237Hz 474Hz 947Hz 1.9kHz 3.8kHz 7.5kHz 15.0kHz/);
	return $bands[$i];
}

sub get_RG_opts
{	my $enable = $::Options{use_replaygain} ? 'yes' : 'no';
	my $mode = $::Options{rg_albummode} ? 'replaygain-album' : 'replaygain-track';
	my $clip = $::Options{rg_limiter} ? 'yes' : 'no';
	my $preamp = $::Options{rg_preamp};
	#FIXME: enforce limits in interface
	$preamp = -15 if $::Options{rg_preamp}<-15;
	$preamp = 15 if $::Options{rg_preamp}>15;
	my $RGstring = "\@RG:volume=0:$mode=$enable:replaygain-clip=$clip:replaygain-preamp=$preamp";
	return $RGstring;
}

sub RG_set_options
{	my $RGstring = get_RG_opts();
	send_cmd('af', 'add', $RGstring);
}

1;
