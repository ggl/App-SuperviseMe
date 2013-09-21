package App::Sv;

# ABSTRACT: Event-based multi-process supervisor
# VERSION
# AUTHORITY

use strict;
use warnings;
use 5.008001;
use version; our $VERSION = version->parse('0.008');

use Carp 'croak';
use POSIX 'strftime';
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Log;

# Constructors
sub new {
	my $class = shift;
	my $conf;
	
	if (@_ && scalar @_ > 1) {
		croak "Odd number of arguments to App::Sv" if @_ % 2 != 0;
		foreach my $id (0..$#_) {
			$conf->{$_[$id]} = $_[$id+1] if $id % 2 == 0;
		}
	}
	else {
		$conf = shift @_;
	}
	
	my $run = $conf->{run};
	$conf->{global}->{log} = delete $conf->{log};
	croak "Commands must be passed as a HASH ref" if ref $run ne 'HASH';
	croak "Missing command list" unless scalar (keys %$run);
	
	# set defaults
	my $defaults = {
		start_retries => 8,
		restart_delay => 1,
		start_wait => 1,
		stop_wait => 0
	};
	# check options
	foreach my $svc (keys %$run) {
		unless ($run->{$svc}) {
			croak "Missing command for \'$svc\'";
		}
		elsif (ref $run->{$svc} ne 'HASH') {
			$run->{$svc} = { cmd => $run->{$svc} };
		}
		elsif (!$run->{$svc}->{cmd}) {
			croak "Missing command for \'$svc\'";
		}
		$run->{$svc}->{name} = $svc;
		foreach my $opt (keys %$defaults) {
			unless (defined $run->{$svc}->{$opt}) {
				$run->{$svc}->{$opt} = $defaults->{$opt};
			}
			elsif ($opt =~ /delay|wait/ && $run->{$svc}->{$opt} <= 0) {
				$run->{$svc}->{$opt} = $defaults->{$opt};
			}
		}
	}
	
	return bless { run => $run, conf => $conf->{global} }, $class;
}

# Start everything
sub run {
	my $self = shift;
	my $cv = AE::cv;
	
	# signal watchers
	my $int_s = AE::signal 'INT' => sub {
		$self->_signal_all_svc('INT', $cv);
	};
	my $hup_s = AE::signal 'HUP' => sub {
		$self->_signal_all_svc('HUP', $cv);
	};
	my $term_s = AE::signal 'TERM' => sub {
		$self->_signal_all_svc('TERM');
		$cv->send
	};
	
	# set global umask
	umask oct($self->{conf}->{umask}) if $self->{conf}->{umask};
	# initialize logger
	$self->_logger();
	# open controling socket; load commands
	$self->_listener() if $self->{conf}->{listen};
	$self->{cmds} = $self->_client_cmds() if ref $self->{server} eq 'Guard';
	
	# start all services
	foreach my $key (keys %{ $self->{run} }) {
		my $svc = $self->{run}->{$key};
		$self->_start_svc($svc);
	}
	
	$cv->recv;
}

sub _start_svc {
	my ($self, $svc) = @_;
	
	my $debug = $self->{log}->logger(8);
	$svc->{state} = 'start';
	if ($svc->{start_count}) {
		$svc->{start_count}++;
	}
	else {
		$svc->{start_count} = 1;
	}
	
	# set process umask
	my $oldmask;
	if ($svc->{umask}) {
		$oldmask = umask;
		umask oct($svc->{umask});
	}
	
	$debug->("Starting '$svc->{name}' attempt $svc->{start_count}");
	my $pid = fork();
	if (!defined $pid) {
		$debug->("fork() failed: $!");
		$self->_restart_svc($svc);
		return;
	}

	# child
	if ($pid == 0) {
		# set egid/euid
		if ($svc->{group}) {
			$svc->{gid} = getgrnam($svc->{group});
			$) = $svc->{gid};
		}
		if ($svc->{user}) {
			$svc->{uid} = getpwnam($svc->{user});
			$> = $svc->{uid};
		}
		my $cmd = $svc->{cmd};
		$debug->("Executing '$cmd'");
		exec($cmd);
		exit(1);
	}

	# parent
	$debug->("Watching pid $pid for '$svc->{name}'");
	$svc->{pid} = $pid;
	$svc->{watcher} = AE::child $pid, sub { $self->_child_exited($svc, @_) };
	$svc->{start_ts} = time;
	umask $oldmask if $oldmask;
	my $t; $t = AE::timer $svc->{start_wait}, 0, sub {
		$self->_check_svc_up($svc);
		undef $t;
	};
	
	return $pid;
}

sub _child_exited {
	my ($self, $svc, undef, $status) = @_;
	
	my $debug = $self->{log}->logger(8);
	$debug->("Child $svc->{pid} exited, status $status: '$svc->{name}'");
	delete $svc->{watcher};
	delete $svc->{pid};
	$svc->{last_status} = $status >> 8; 
	if ($svc->{state} eq 'stop') {
		delete $svc->{start_count};
		$svc->{state} = 'down';
	}
	elsif ($svc->{once}) {
		delete $svc->{start_count};
		$svc->{state} = 'fatal';
	}
	else {
		$self->_restart_svc($svc);
	}
}

sub _restart_svc {
	my ($self, $svc) = @_;

	if ($svc->{start_retries}) {
		if ($svc->{start_count} &&
			($svc->{start_count} >= $svc->{start_retries})) {
			$svc->{state} = 'fatal';
			return;
		}
	}
	else {
		$svc->{state} = 'fatal';
		return;
	}
	my $debug = $self->{log}->logger(8);
	$svc->{state} = 'restart';
	$debug->("Restarting '$svc->{name}' in $svc->{restart_delay} seconds");
	my $t; $t = AE::timer $svc->{restart_delay}, 0, sub {
		$self->_start_svc($svc);
		undef $t;
	};
}

sub _check_svc_up {
	my ($self, $svc) = @_;
	
	return unless $svc->{state} eq 'start';
	if (!$svc->{pid}) {
		$svc->{state} = 'fail';
		return;
	}
	delete $svc->{start_count};
	$svc->{state} = 'up';
}

sub _stop_svc {
	my ($self, $svc) = @_;
	
	$svc->{state} = 'stop';
	my $st = $self->_signal_svc($svc, 'TERM');
	if ($svc->{stop_wait} && $svc->{stop_wait} > 0) {
		my $t; $t = AE::timer $svc->{stop_wait}, 0, sub {
			$self->_check_svc_down($svc);
			undef $t;
		};
	}
	
	return $st;
}

sub _check_svc_down {
	my ($self, $svc) = @_;
	
	return unless $svc->{state} eq 'stop';
	if ($svc->{pid}) {
		my $st = $self->_signal_svc($svc, 'KILL');
	}
}

sub _signal_svc {
	my ($self, $svc, $sig) = @_;
	
	return unless ($svc->{pid} && $sig);
	my $debug = $self->{log}->logger(8);
	$debug->("Sent signal $sig to pid $svc->{pid}");
	my $st = kill($sig, $svc->{pid});
	
	return $st;
}

sub _signal_all_svc {
	my ($self, $sig, $cv) = @_;
	
	my $debug = $self->{log}->logger(8);
	$debug->("Received signal $sig");
	my $is_any_alive = 0;
	foreach my $key (keys %{ $self->{run} }) {
		my $svc = $self->{run}->{$key};
		next unless my $pid = $svc->{pid};
		$debug->("... sent signal $sig to pid $pid");
		$is_any_alive++;
		kill($sig, $pid);
	}

	return if $cv and $is_any_alive;

	$debug->('Exiting...');
	$cv->send if $cv;
}

# Contolling socket
sub _listener {
	my $self = shift;
	
	my $debug = $self->{log}->logger(8);
	my ($host, $port) = parse_hostport($self->{conf}->{listen});
	croak "Socket \'$port\' already in use" if ($host eq 'unix/' && -e $port);
	
	$self->{server} = tcp_server $host, $port,
	sub { $self->_client_conn(@_) },
	sub {
		my ($fh, $host, $port) = @_;
		$debug->("Listener bound to $host:$port");
	};
}

sub _client_conn {
	my ($self, $fh, $host, $port) = @_;
	
	return unless $fh;
	my $debug = $self->{log}->logger(8);
	$debug->("New connection to $host:$port");
	
	my $hdl; $hdl = AnyEvent::Handle->new(
		fh => $fh,
		timeout => 30,
		rbuf_max => 64,
		wbuf_max => 64,
		on_read => sub { $self->_client_input($hdl) },
		on_eof => sub { $self->_client_disconn($hdl) },
		on_timeout => sub { $self->_client_error($hdl, undef, 'Timeout') },
		on_error => sub { $self->_client_error($hdl, undef, $!) }
	);
	$self->{conn}->{fileno($fh)} = $hdl;
	
	return $fh;
}

sub _client_input {
	my ($self, $hdl) = @_;
	
	$hdl->push_read(line => sub {
		my ($hdl, $ln) = @_;
		
		my $client = $self->{conn}->{fileno($hdl->fh)};
		my $cmds = $self->{cmds};
		if ($ln) {
			# generic commands
			$hdl->push_write("\n");
			if ($ln =~ /^(\.|quit)$/) {
				$self->_client_disconn($hdl);
			}
			elsif ($ln eq 'status') {
				$self->_status($hdl);
			}
			elsif (index($ln, ' ') >= 0) {
				my ($sw, $svc) = split(' ', $ln);
				if ($sw && $svc) {
					my $st;
					if ($self->{run}->{$svc} && ref $cmds->{$sw} eq 'CODE') {
						$svc = $self->{run}->{$svc};
						$st = $cmds->{$sw}->($svc);
					}
					else {
						$hdl->push_write("$ln unknown\n");
						return;
					}
					# response
					$st = ref $st eq 'ARRAY' ? join(' ', @$st) : $st;
					$st = $st ? $st : 'fail';
					$hdl->push_write("$ln $st\n") if $st;
				}
			}
			else {
				$hdl->push_write("$ln unknown\n");
			}
		}
	});
}

sub _client_disconn {
	my ($self, $hdl) = @_;
	
	my $debug = $self->{log}->logger(8);
	delete $self->{conn}->{fileno($hdl->fh)};
	$hdl->destroy();
	$debug->("Connection closed");
}

sub _client_error {
	my ($self, $hdl, $fatal, $msg) = @_;
	
	my $debug = $self->{log}->logger(8);
	delete $self->{conn}->{fileno($hdl->fh)};
	$debug->("Connection error: $msg");
	$hdl->destroy();
}

sub _client_cmds {
	my $self = shift;
	
	my $cmds = {
		up => sub {
			unless ($_[0]->{pid}) {
				delete $_[0]->{once};
				return $self->_start_svc($_[0]);
			}
		},
		once => sub {
			unless ($_[0]->{pid}) {
				$_[0]->{once} = 1;
				return $self->_start_svc($_[0]);
			}
		},
		down => sub {
			return $self->_stop_svc($_[0]) if $_[0]->{pid};
		},
		pause => sub {
			return $self->_signal_svc($_[0], 'STOP') if $_[0]->{pid};
		},
		cont => sub {
			return $self->_signal_svc($_[0], 'CONT') if $_[0]->{pid};
		},
		hup => sub {
			return $self->_signal_svc($_[0], 'HUP') if $_[0]->{pid};
		},
		alarm => sub {
			return $self->_signal_svc($_[0], 'ALRM') if $_[0]->{pid};
		},
		int => sub {
			return $self->_signal_svc($_[0], 'INT') if $_[0]->{pid};
		},
		quit => sub {
			return $self->_signal_svc($_[0], 'QUIT') if $_[0]->{pid};
		},
		usr1 => sub {
			return $self->_signal_svc($_[0], 'USR1') if $_[0]->{pid};
		},
		usr2 => sub {
			return $self->_signal_svc($_[0], 'USR2') if $_[0]->{pid};
		},
		term => sub {
			return $self->_signal_svc($_[0], 'TERM') if $_[0]->{pid};
		},
		kill => sub {
			return $self->_signal_svc($_[0], 'KILL') if $_[0]->{pid};
		},
		status => sub {
			if ($_[0]->{pid} && $_[0]->{start_ts}) {
				return([
					$_[0]->{state},
					$_[0]->{pid},
					time - $_[0]->{start_ts}
				]);
			}
			elsif ($_[0]->{start_count}) {
				return([
					$_[0]->{state},
					$_[0]->{start_count}
				]);
			}
			else {
				return $_[0]->{state};
			}
		}
	};
	
	return $cmds;
}

# Commands status
sub _status {
	my ($self, $hdl) = @_;
	
	return unless ($hdl && ref $self->{cmds}->{status} eq 'CODE');
	foreach my $key (keys %{ $self->{run} }) {
		my $st = $self->{cmds}->{status}->($self->{run}->{$key});
		$st = ref $st eq 'ARRAY' ? join(' ', @$st) : $st;
		$hdl->push_write("$key $st\n");
	}
}

# Loggers

sub _logger {
	my $self = shift;
	
	my $log = $self->{conf}->{log};
	my $ctx; $ctx = AnyEvent::Log::Ctx->new(
		title => __PACKAGE__,
		fmt_cb => sub { $self->_log_format(@_) }
	);
	
	# set output
	if ($log->{file}) {
		$ctx->log_to_file($log->{file});
	}
	elsif (-t \*STDOUT && -t \*STDIN) {
		$ctx->log_cb(sub { print @_ });
	}
	elsif (-t \*STDERR) {
		$ctx->log_cb(sub { print STDERR @_ });
	}
	
	# set log level
	if ($ENV{SV_DEBUG}) {
		$ctx->level(8);
	}
	elsif ($log->{level}) {
		$ctx->level($log->{level});
	}
	else {
		$ctx->level(5);
	}
	
	$self->{log} = $ctx;
}

sub _log_format {
	my ($self, $ts, $ctx, $lvl, $msg) = @_;
	
	my $ts_fmt =  $self->{conf}->{log}->{ts_format} || "%Y-%m-%dT%H:%M:%S%z";
	my @levels = qw(0 fatal alert crit error warn note info debug trace);
	$ts = strftime($ts_fmt, localtime((int $ts)[0]));
	
	return "$ts $levels[$lvl] [$$] $msg\n"
}

1;

__END__

=encoding utf8

=head1 NAME

App::Sv - Event-based multi-process supervisor

=head1 SYNOPSIS

    my $sv = App::Sv->new(
        run => {
          x => 'plackup -p 3010 ./sites/x/app.psgi',
          y => {
            cmd => 'plackup -p 3011 ./sites/y/app.psgi'
            start_retries => 5,
            restart_delay => 1,
            start_wait => 1,
            stop_wait => 2,
            umask => '027',
            user => 'www',
            group => 'www'
          },
        },
        global => {
          listen => '127.0.0.1:9999',
          umask => '077'
        },
    );
    $sv->run;


=head1 DESCRIPTION

This module implements an event-based multi-process supervisor.

It takes a list of commands to execute and starts each one, and then monitors
their execution. If one of the programs dies, the supervisor will restart it
after C<restart_delay> seconds. If a program respawns during C<restart_delay>
for C<start_retries> times, the supervisor gives up and stops it indefinitely.

You can send SIGTERM to the supervisor process to kill all children and exit.

You can also send SIGINT (Ctrl-C on your terminal) to restart the processes. If
a second SIGINT is received and no child process is currently running, the
supervisor will exit. This allows you to tap Ctrl-C twice in quick succession
in a terminal window to terminate the supervisor and all child processes.


=head1 METHODS

=head2 new

    my $sv = App::Sv->new({ run => {...}, global => {...}, log => {...} });

Creates a supervisor instance with a list of commands to monitor.

It accepts an anonymous hash with the following options:

=over 4

=item run

A hash reference with the commands to execute and monitor. Each command can be
a scalar, or a hash reference.

=item run->{$name}->{cmd}

The command to execute and monitor, along with command line options. Each
command should be a scalar. This can also be passed as C<run-E<gt>{$name}> if
no other options are specified. In this case the supervisor will use the
default values.

=item run->{$name}->{start_retries}

Specifies the number of execution attempts. For every command execution that
fails within C<restart_delay>, a counter is incremented until it reaches this
value when no further execution attempts are made and the service is marked as 
I<fatal>. Otherwise the counter is reset. A null value disables restart; for 
negative values restart is attempted indefinitely. The default value for this
option is 8 start attempts.

=item run->{$name}->{restart_delay}

Delay service restart by this many seconds. The default is 1 second. For null
and negative values, the default is used.

=item run->{$name}->{start_wait}

Number of seconds to wait before checking if the service is up and running and
updating its state accordingly. The default is 1 second. For null and negative
values, the default is used.

=item run->{$name}->{stop_wait}

Number of seconds to wait before checking if the service has stopped and
sending it SIGKILL if it hasn't. The default is 0, meaning forced service
shutdown is disabled. For null and negative values, the default is used.

=item run->{$name}->{umask}

This option sets the specified umask before executing the command. Its value is
converted to octal.

=item run->{$name}->{user}

Specifies the user name to run the command as.

=item run->{$name}->{group}

Specifies the group to run the command as.

=item global

A hash reference with the global configuration.

=item global->{listen}

The C<host:port> to listen on. Also accepts unix domain sockets, in which case
the host part should be C<unix:/> and the port part should be the path to the
socket. If this is a TCP socket, then the host part should be an IP address.

=item global->{umask}

This option sets the umask for the supervisor process. Its value is converted
to octal. This acts as a global umask when no C<run-E<gt>{$name}-E<gt>{umask}>
option is set.

=item log

A hash reference with the logging options.

=item log->{level}

Enables logging at the given level and all lower (higher priority) levels. This
should be an integer between 1 (fatal) and 9 (trace). For the actual names, see
L<AnyEvent::Log>. If C<SV_DEBUG> is set, this defaults to 8 (debug), otherwise
it defaults to 5 (warn).

=item log->{file}

If this option is set, all the log messages are appended to this file. By
default messages go to STDOUT or STDERR, whichever is open. By default logging
goes to STDOUT.

=item log->{ts_format}

This option defines timestamp format for the log messages, using C<strftime>.
The default format is "%Y-%m-%dT%H:%M:%S%z".

=back

=head2 run

    $sv->run;

Starts the supervisor, forks and executes all the services in child processes
and monitors each one.

This method returns when the supervisor is stopped with either a SIGINT or a
SIGTERM.

=head1 ENVIRONMENT

=over 4

=item SV_DEBUG 

If set to a true value, the supervisor will show debugging information.

=back

=head1 SEE ALSO

L<App::SuperviseMe>, L<ControlFreak>, L<Supervisor>

=cut
