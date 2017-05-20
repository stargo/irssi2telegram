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

my $idletime;
my $longpoll;

my $cfg;

my $debug;

my $last_ts = 0;
my $offset = -1;
my $last_target;
my $last_server;

sub telegram_getupdates();
sub telegram_send_message($$);

sub telegram_handle_message {
	my ($json) = @_;

	return if (!$json->{ok});
	return if (!defined($json->{result}));

	foreach my $msg (@{$json->{result}}) {
		$offset = $msg->{update_id} if (defined($msg->{update_id}) && ($offset < $msg->{update_id}));
		next if (!defined($msg->{message}));

		next if (!defined($msg->{message}->{text}));

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

		next if (!defined($last_target));
		next if (!defined($last_server));

		my $cmd = "msg ${last_target} ".$msg->{message}->{text};
		print $cmd if ($debug);
		$last_server->command($cmd);
		telegram_send_message($user, "->${last_target}");
	}
}

sub telegram_connect {
	my ($source) = @_;

	Irssi::input_remove($source->{tag}) if (defined($source->{tag}));

	#$source->{s}->connect_SSL is needed when run in irssi for some reason...
	if ($source->{s}->connected || $source->{s}->connect_SSL) {
		$source->{s}->write_request(GET => $source->{uri});
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
		telegram_getupdates() if ($source->{poll});
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
		my $rsp = HTTP::Response->parse($buf);
		if ($rsp->is_success) {
			my $json = decode_json($rsp->decoded_content);
			if (defined($json)) {
				print Dumper($json) if ($debug);
				telegram_handle_message($json) if ($source->{poll});
			} else {
				print $rsp->decoded_content if ($debug);
			}
		}
	}

	if ($done) {
		print "Request done" if ($debug);
		Irssi::input_remove($source->{tag}) if (defined($source->{tag}));
		$source->{s}->close();
		telegram_getupdates() if ($source->{poll});
	}
}

sub telegram_https {
	my ($uri, $poll) = @_;

	my $s = Net::HTTPS::NB->new(Host => "api.telegram.org", SSL_verifycn_name => "api.telegram.org", Blocking => 0) || return;
	$s->blocking(0);

	my $source = { s => $s, uri => $uri, poll => $poll };

	telegram_connect($source);
}

sub telegram_send_message($$) {
	my ($chat, $msg) = @_;

	my $uri = URI::Encode->new({encode_reserved => 1});
	my $encoded = $uri->encode("${msg}");

	telegram_https("/bot${token}/sendMessage?chat_id=${chat}&text=${encoded}", undef);
}

sub telegram_getupdates() {
	telegram_https("/bot${token}/getUpdates?offset=".($offset + 1)."&timeout=${longpoll}", 1);
}

sub telegram_signal {
	my ($server, $msg, $nick, $address, $target) = @_;

	my $query = 0;
	my $from = $nick;

	print "Idle: " . (time() - $last_ts) if ($debug);
	return if ((time() - $last_ts < $idletime) && !$debug);

	if (!defined($target)) {
		$target = $nick;
		$query = 1;
	} else {
		$from .= "(${target})";
	}

	return if (!$query && !grep(/stargo/, $msg));

	$last_target = $target;
	$last_server = $server;
	telegram_send_message($user, "${from}: ${msg}");
}

sub telegram_idle {
        my ($text, $server, $item) = @_;

	$last_ts = time();
}

$cfg = new Config::Simple($cfgfile) || die "Can't open ${cfgfile}: $!";
$token = $cfg->param('token') || die "No token defined in config!";
$user = $cfg->param('user') || die "No user defined in config!";

$idletime = $cfg->param('idletime');
$idletime = "300" if (!defined($idletime));
$idletime = int($idletime);

$longpoll = $cfg->param('longpoll');
$longpoll = "600" if (!defined($longpoll));
$longpoll = int($longpoll);

$debug = $cfg->param('debug');

telegram_getupdates();

Irssi::signal_add("message public", "telegram_signal");
Irssi::signal_add("message private", "telegram_signal");
Irssi::signal_add('send text', 'telegram_idle');
