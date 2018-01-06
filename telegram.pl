# Copyright (c) 2017 Michael Gernoth <michael@gernoth.net>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

use strict;
use vars qw($VERSION %IRSSI);
use Irssi;
use HTTP::Response;
use Net::HTTPS::NB;
use URI::Encode;
use Data::Dumper;
use IO::Select;
use JSON;
use Config::Simple;
use Errno qw/EAGAIN EWOULDBLOCK/;

my $cfgfile = $ENV{HOME}."/.irssi/telegram.cfg";

my $token;
my $user;
my $matchPattern;

my $idletime;
my $longpoll;

my $baseURL;
my $localPath;

my $cfg;

my $debug;

my $last_poll = 0;
my $last_ts = 0;
my $offset = -1;
my %servers; # maps channels to servers
my $last_target;
my $last_server;

sub telegram_getupdates($);
sub telegram_send_message($$;$);
sub telegram_https($$$$);

sub telegram_send_to_irc($;$) {
	my ($text, $data) = @_;

	if ($text =~ m/^[#@]/) {
		# post in specific channel
		(my $chan, my $text) = split(/ /, $text, 2);
		$chan =~ s/^\@//;
		my $cmd = "msg ${chan} ".$text;
		print $cmd if ($debug);
		my $srv = $servers{$chan};
		if (!defined($srv)) {
			my @targets = ();
			if ($chan =~ m/^#/) {
				@targets = Irssi::channels();
			} else {
				@targets = Irssi::queries();
			}

			foreach my $target (@targets) {
				if ($target->{name} eq $chan) {
					$srv = $target->{server};
					last;
				}
			}
		}
		if (defined $srv) {
			if (length($text)) {
				$srv->command($cmd);
				telegram_send_message($user, "->${chan}");
			} else {
				telegram_send_message($user, "${chan} on $srv->{tag} selected as new target.");
			}
			$last_target = $chan;
			$last_server = $srv;
		} else {
			print "no server known for channel '$chan'";
			telegram_send_message($user, "no server known for channel '$chan'");
		}
	} else {
		# post in last channel
		my $target = $last_target;
		my $server = $last_server;

		$target = $data->{last_target} if (defined($data) && defined($data->{last_target}));
		$server = $data->{last_server} if (defined($data) && defined($data->{last_server}));

		if ((!defined($target)) || (!defined($server))) {
			telegram_send_message($user, "Can't determine target to send message to. Please specify either a channel with #channel or query with \@nick.");
			return;
		}

		my $cmd = "msg ${target} ".$text;
		print $cmd if ($debug);
		$server->command($cmd);
		telegram_send_message($user, "->${target}");
	}
}

sub telegram_handle_message {
	my ($json) = @_;

	return if (!$json->{ok});
	return if (!defined($json->{result}));

	foreach my $msg (@{$json->{result}}) {
		#Ignore messages without id
		next if (!defined($msg->{update_id}));
		#Ignore messages already seen
		next if ($msg->{update_id} <= $offset);
		$offset = $msg->{update_id};

		next if (!defined($msg->{message}));

		next if (!defined($msg->{message}->{from}));
		next if (!defined($msg->{message}->{from}->{id}));
		if ($msg->{message}->{from}->{id} ne $user) {
			print "telegram message from unknown user " .
				$msg->{message}->{from}->{username} . ", id: " .
				$msg->{message}->{from}->{id};
			next;
		}

		next if (!defined($msg->{message}->{chat}));
		next if (!defined($msg->{message}->{chat}->{id}));
		next if ($msg->{message}->{chat}->{id} ne $user);

		my $text = $msg->{message}->{text};
		if (!defined($text)) {
			my $data;
			$data->{text} = $msg->{message}->{caption};
			$data->{last_target} = $last_target;
			$data->{last_server} = $last_server;

			my $file;
			if (defined($msg->{message}->{photo})) {
				my $photo = ${$msg->{message}->{photo}}[$#{$msg->{message}->{photo}}];
				$file = $photo->{file_id} if (defined($photo));
			} else {
				foreach my $doctype (qw(document video audio voice video_note sticker)) {
					if (defined($msg->{message}->{$doctype})) {
						$file = $msg->{message}->{$doctype}->{file_id};
						$data->{extension} = ".webp" if ($doctype eq "sticker");
						last;
					}
				}
			}

			if (defined($file) && defined($baseURL) && defined($localPath)) {
				print("Requesting ".$file) if ($debug);
				$data->{file_id} = $file;
				telegram_https("/bot${token}/getFile?file_id=${file}", undef, undef, $data);
			}

			next;
		}

		next if (!defined($text));

		telegram_send_to_irc($text);
	}
}

sub telegram_handle_response {
	my ($rsp, $data) = @_;

	if (defined($data->{file_id}) && (!defined($data->{file_path}))) {
		my $json = decode_json($rsp);
		return if (!defined($json));
		return if (!defined($json->{result}));
		return if (!defined($json->{result}->{file_path}));
		print("Downloading ".$json->{result}->{file_path}) if ($debug);

		$data->{file_path} = $json->{result}->{file_path};

		telegram_https("/file/bot${token}/".$json->{result}->{file_path}, undef, undef, $data);
	} else {
		my $fname = $data->{file_id} . "_" . $data->{file_path};
		$fname =~ s/\//_/g;
		$fname .= $data->{extension} if (defined($data->{extension}) && $fname !~ m/$data->{extension}$/);
		print("Saving download as ".$localPath."/".$fname) if ($debug);
		open(my $fd, ">", $localPath."/".$fname) or return;
		print $fd $rsp;
		close($fd);

		my $text = $baseURL . "/" . $fname;
		$text = $data->{text} . " " . $text if (defined($data->{text}));

		telegram_send_to_irc($text, $data);
	}
}


sub telegram_connect {
	my ($source) = @_;

	Irssi::input_remove($source->{tag}) if (defined($source->{tag}));

	#$source->{s}->connect_SSL is needed when run in irssi for some reason...
	if ($source->{s}->connected || ($source->{s}->can('connect_SSL') && $source->{s}->connect_SSL)) {
		if (defined($source->{body})) {
			$source->{s}->write_request("POST", $source->{uri}, ("Content-Type" => "application/json"), $source->{body});
		} else {
			$source->{s}->write_request("GET", $source->{uri});
		}
		$source->{tag} = Irssi::input_add(fileno($source->{s}), Irssi::INPUT_READ, "telegram_poke", $source);
		print "Add ".$source->{tag} if ($debug);
		return;
	}

	if ($HTTPS_ERROR == HTTPS_WANT_READ) {
		$source->{tag} = Irssi::input_add(fileno($source->{s}), Irssi::INPUT_READ, "telegram_connect", $source);
	} elsif($HTTPS_ERROR == HTTPS_WANT_WRITE) {
		$source->{tag} = Irssi::input_add(fileno($source->{s}), Irssi::INPUT_WRITE, "telegram_connect", $source);
	} else {
		$source->{s}->close();
		telegram_getupdates($source) if ($source->{poll});
	}
}

sub telegram_poke {
	my ($source) = @_;

	my $buf;
	my $n;
	my $done = 0;
	# try to read until error or all data received
	while (1) {
		my $tmp_buf;
		$n = $source->{s}->read_entity_body($tmp_buf, 1024);
		if ($n == -1 || (!defined($n) && ($! == EWOULDBLOCK || $! == EAGAIN))) {
			last; # no data available this time
		}
		elsif ($n) {
			$buf .= $tmp_buf; # data received
		}
		elsif (defined $n) {
			print "Remove ".$source->{tag}." (done)" if ($debug);
			$done = 1;
			last; # $n == 0, all readed
		}
		else {
			print "Remove ".$source->{tag}." (error)" if ($debug);
			$done = 1;
			last;
		}
	}

	$source->{buf} .= $buf if (length($buf));

	if (defined($n) && $n == 0 && defined($source->{buf})) {
		my $rsp = HTTP::Response->parse($source->{buf});
		if ($rsp->is_success) {
			if (defined($source->{data})) {
				telegram_handle_response($rsp->decoded_content, $source->{data});
			} else {
				my $json = decode_json($rsp->decoded_content);
				if (defined($json)) {
					print Dumper($json) if ($debug);
					telegram_handle_message($json) if ($source->{poll});
				} else {
					print $rsp->decoded_content if ($debug);
				}
			}
		}
		$done = 1;
	}

	if ($done) {
		print "Request done" if ($debug);
		Irssi::input_remove($source->{tag}) if (defined($source->{tag}));
		$source->{s}->close();
		if ($source->{poll}) {
			telegram_getupdates($source);
		}
	}
}

sub telegram_https($$$$) {
	my ($uri, $body, $poll, $data) = @_;

	my $s = Net::HTTPS::NB->new(Host => "api.telegram.org", SSL_verifycn_name => "api.telegram.org", Blocking => 0) || return;
	$s->blocking(0);

	my $source = { s => $s, uri => $uri, poll => $poll, time => time(), body => $body, data => $data };
	$last_poll = $source->{time} if ($poll);

	telegram_connect($source);
}

sub telegram_send_message($$;$) {
	my ($chat, $msg, $reply_markup) = @_;

	utf8::decode($msg);

	my $body = { chat_id => $chat, text => $msg, reply_markup => $reply_markup };
	$body->{reply_markup} = {remove_keyboard => JSON::true} if (!defined($reply_markup));
	$body = encode_json($body);
	telegram_https("/bot${token}/sendMessage", $body, undef, undef);
	print $body if ($debug);
}

sub telegram_getupdates($) {
	my ($source) = @_;

	#If we have already started another longpoll, don't restart the
	#old one
	if (defined($source) && $source->{poll} && $source->{time} != $last_poll) {
		print "Removing getupdate request as token differs: $source->{time} != ${last_poll}";
		return;
	}

	telegram_https("/bot${token}/getUpdates?offset=".($offset + 1)."&timeout=${longpoll}", undef, 1, undef);
}

sub telegram_signal {
	my ($server, $msg, $nick, $address, $target) = @_;

	my $query = 0;
	my $from = $nick;

	telegram_getupdates(undef) if ($last_poll < (time() - ($longpoll * 2)));

	if (!defined($target)) {
		$target = $nick;
		$query = 1;
	} else {
		$from .= "(${target})";
	}

	$servers{$target} = $server;

	print "Idle: " . (time() - $last_ts) if ($debug);
	return if ((time() - $last_ts < $idletime) && !$debug);

	return if (!$query && !grep(/$matchPattern/, $msg));

	my $reply_markup;
	if ((!defined($last_target)) ||
	    (!defined($last_server)) ||
	    ($target ne $last_target) ||
	    ($server->{tag} ne $last_server->{tag})) {
		my $dst = $target;
		$dst = '@'.$dst if ($dst !~ m/^#/);
		$reply_markup = {
			keyboard => [
					[{text => $dst}],
				],
			one_time_keyboard => JSON::true,
			};
	}

	telegram_send_message($user, "${from}: ${msg}", $reply_markup);
}

sub telegram_signal_private {
	my ($server, $msg, $nick, $address, $target) = @_;

	return telegram_signal($server, $msg, $nick, $address, undef);
}

sub telegram_idle {
        my ($text, $server, $item) = @_;

	$last_ts = time();
}

$cfg = new Config::Simple($cfgfile) || die "Can't open ${cfgfile}: $!";
$token = $cfg->param('token') || die "No token defined in config!";
$user = $cfg->param('user') || die "No user defined in config!";
$matchPattern = $cfg->param('matchPattern');
$matchPattern = "." if (!defined($matchPattern));

$idletime = $cfg->param('idletime');
$idletime = "300" if (!defined($idletime));
$idletime = int($idletime);

$longpoll = $cfg->param('longpoll');
$longpoll = "600" if (!defined($longpoll));
$longpoll = int($longpoll);

$baseURL = $cfg->param('baseURL');
$localPath = $cfg->param('localPath');

$debug = $cfg->param('debug');

telegram_getupdates(undef);

Irssi::signal_add("message public", "telegram_signal");
Irssi::signal_add("message private", "telegram_signal_private");
Irssi::signal_add('send text', 'telegram_idle');
