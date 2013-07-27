package App::Sv;

# ABSTRACT: Simple process supervisor
# VERSION
# AUTHORITY

use strict;
use warnings;
use Carp 'croak';
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Log;
use Data::Dumper;


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
	croak "Commands must be passed as a HASH ref" unless ref($run) eq 'HASH';
	croak "Missing command list" unless scalar (keys %$run) > 0;
	
	# set default options
	my $defaults = {
		start_delay => 1,
		start_retries => 10,
		stop_signal => 'TERM',
		reload_signal => 'HUP',
	};
	foreach my $cmd (keys %$run) {
		$run->{$cmd} = { cmd => $run->{$cmd} } 
			if (ref($run->{$cmd}) ne 'HASH');
		croak "Missing command for \'$cmd\'" unless $run->{$cmd}->{cmd};
		foreach my $opt (keys %$defaults) { 
			$run->{$cmd}->{$opt} = $defaults->{$opt}
				unless defined $run->{$cmd}->{$opt};
		}
	}
	
	return bless { run => $run, conf => $conf->{global} }, $class;
}

# Start everything
sub run {
	my $self = shift;
	my $sv = AE::cv;
	
	my $int_s = AE::signal 'INT' => sub {
		$self->_signal_all_cmds('INT', $sv);
	};
	my $hup_s = AE::signal 'HUP' => sub {
		$self->_signal_all_cmds('HUP', $sv);
	};
	my $term_s = AE::signal 'TERM' => sub {
		$self->_signal_all_cmds('TERM');
		$sv->send
	};
	
	# set global umask
	umask oct($self->{conf}->{umask}) if $self->{conf}->{umask};
	
	# initialize logger
	$self->_logger();
	
	# open controling socket
	$self->_listener() if $self->{conf}->{listen};
	
	# start all processes
	foreach my $key (keys %{ $self->{run} }) {
		my $cmd = $self->{run}->{$key};
		$self->_start_cmd($cmd);
	}
	
	$sv->recv;
}

sub _start_cmd {
	my ($self, $cmd) = @_;
	
	my $debug = $self->{log}->logger(8);
	if ($cmd->{start_count}) {
		$cmd->{start_count}++;
	}
	else {
		$cmd->{start_count} = 1;
	}
	$debug->("Starting '$cmd->{cmd}' attempt $cmd->{start_count}");
	
	# set process umask
	my $oldmask;
	if ($cmd->{umask}) {
		$oldmask = umask;
		umask oct($cmd->{umask});
	}
	
	my $pid = fork();
	if (!defined $pid) {
		$debug->("fork() failed: $!");
		$self->_restart_cmd($cmd);
		return;
	}

	# child
	if ($pid == 0) {
		# set egid/euid
		if ($cmd->{group}) {
			$cmd->{gid} = getgrnam($cmd->{group});
			$) = $cmd->{gid};
		}
		if ($cmd->{user}) {
			$cmd->{uid} = getpwnam($cmd->{user});
			$> = $cmd->{uid};
		}
		$cmd = $cmd->{cmd};
		$debug->("Executing '$cmd'");
		exec($cmd);
		exit(1);
	}

	# parent
	$debug->("Watching pid $pid for '$cmd->{cmd}'");
	$cmd->{pid} = $pid;
	$cmd->{watcher} = AE::child $pid, sub { $self->_child_exited($cmd, @_) };
	$cmd->{start_ts} = time;
	umask $oldmask if $oldmask;
	
	return $pid;
}

sub _child_exited {
	my ($self, $cmd, undef, $status) = @_;
	
	my $debug = $self->{log}->logger(8);
	$debug->("Child $cmd->{pid} exited, status $status: \'$cmd->{cmd}\'");
	delete $cmd->{watcher};
	delete $cmd->{pid};
	delete $cmd->{start_count}
		if (time - $cmd->{start_ts} > $cmd->{start_delay});
	$cmd->{last_status} = $status >> 8;
	$self->_restart_cmd($cmd);
}

sub _restart_cmd {
	my ($self, $cmd) = @_;

	return if ($cmd->{start_retries} && $cmd->{start_count} && 
		($cmd->{start_count} >= $cmd->{start_retries}));
	my $debug = $self->{log}->logger(8);
	$debug->("Restarting '$cmd->{cmd}' in $cmd->{start_delay} seconds");
	my $t; $t = AE::timer $cmd->{start_delay}, 0, sub {
		$self->_start_cmd($cmd);
		undef $t;
	};
}

sub _stop_cmd {
	my ($self, $cmd) = @_;
	
	my $debug = $self->{log}->logger(8);
	$debug->("Sent signal $cmd->{stop_signal} to $cmd->{pid}");
	my $st = kill($cmd->{stop_signal}, $cmd->{pid});
	map { delete $cmd->{$_} } (qw(watcher pid start_count)) if $st;
	
	return $st;
}

sub _signal_cmd {
	my ($self, $cmd, $signal) = @_;
	
	return unless ($cmd->{pid} && $signal);
	my $debug = $self->{log}->logger(8);
	$debug->("Sent signal $signal to $cmd->{pid}");
	my $st = kill($signal, $cmd->{pid});
	
	return $st;
}

sub _signal_all_cmds {
	my ($self, $signal, $cv) = @_;
	
	my $debug = $self->{log}->logger(8);
	$debug->("Received signal $signal");
	my $is_any_alive = 0;
	foreach my $key (keys %{ $self->{run} }) {
		my $cmd = $self->{run}->{$key};
		next unless my $pid = $cmd->{pid};
		$debug->("... sent signal $signal to $pid");
		$is_any_alive++;
		kill($signal, $pid);
	}

	return if $cv and $is_any_alive;

	$debug->('Exiting...');
	$cv->send if $cv;
}

# Contolling socket listener
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
	#$self->_status($hdl);
	
	return $fh;
}

sub _client_input {
	my ($self, $hdl) = @_;
	
	$hdl->push_read(line => sub {
		my ($hdl, $ln) = @_;
		
		my $client = $self->{conn}->{fileno($hdl->fh)};
		if ($ln) {
			# generic commands
			$hdl->push_write("\n");
			if ($ln =~ /^(\.|quit)$/) {
				$self->_client_disconn($hdl);
			}
			elsif ($ln eq 'status') {
				$self->_status($hdl);
			}
			elsif ($ln =~ / /) {
				my ($sw, $cmd) = split(' ', $ln);
				if ($sw && $cmd) {
					my $st;
					if ($self->{run}->{$cmd}) {
						$cmd = $self->{run}->{$cmd}
					}
					else {
						$hdl->push_write("$ln unknown\n");
						return;
					}
					# control commands
					if ($sw eq 'stop') {
						$st = $self->_stop_cmd($cmd) if $cmd->{pid};
					}
					elsif ($sw eq 'start') {
						$st = $self->_start_cmd($cmd) unless $cmd->{pid};
					}
					elsif ($sw eq 'reload') {
						$st = $self->_signal_cmd($cmd, $cmd->{reload_signal})
							if $cmd->{pid};
					}
					elsif ($sw eq 'restart') {
						$st = $self->_signal_cmd($cmd, $cmd->{stop_signal})
							if $cmd->{pid};
					}
					# response
					$st = $st ? $st : 'fail';
					$hdl->push_write("$ln $st\n") if $st;
					undef $st;
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

# Commands status
sub _status {
	my ($self, $hdl) = @_;
	
	return unless $hdl;
	foreach my $cmd (keys %{ $self->{run} }) {
		my $name = $cmd;
		$cmd = $self->{run}->{$cmd};
		if ($cmd->{pid}) {
			my $uptime = time - $cmd->{start_ts};
			$hdl->push_write("$name up $uptime $cmd->{pid}\n");
		}
		elsif ($cmd->{start_count}) {
			$hdl->push_write("$name fail $cmd->{start_count}\n");
		}
		else {
			$hdl->push_write("$name down\n");
		}
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
	
	my $ts_fmt = "%Y-%m-%dT%H:%M:%S%z";
	my @levels = qw(0 fatal alert crit error warn note info debug trace);
	require POSIX;
	$ts = POSIX::strftime($ts_fmt, gmtime((int $ts)[0]));
	
	return "$ts $levels[$lvl] [$$] $msg\n"
}

1;

__END__

=encoding utf8

=head1 SYNOPSIS

    my $sv = App::Sv->new(
        run => {
          x => 'plackup -p 3010 ./sites/x/app.psgi',
          y => {
            cmd => 'plackup -p 3011 ./sites/y/app.psgi'
            start_delay => 1,
            start_retries => 5,
            stop_signal => 'TERM',
            reload_signal => 'HUP',
            umask => 0027,
            user => 'www',
            group => 'www'
          },
        },
        global => {
          listen => '127.0.0.1:9999',
          daemon => 0,
          umask => 077
        }
    );
    $sv->run;


=head1 DESCRIPTION

This module implements a multi-process supervisor.

It takes a list of commands to execute and starts each one, and then monitors
their execution. If one of the programs dies, the supervisor will restart it
after start_delay seconds. If a program respawns during start_delay for
start_retries times, the supervisor gives up and stops it indefinitely.

You can send SIGTERM to the supervisor process to kill all childs and exit.

You can also send SIGINT (Ctrl-C on your terminal) to restart the processes. If
a second SIGINT is received and no child process is currently running, the
supervisor will exit. This allows you to tap Ctrl-C twice in quick succession
in a terminal window to terminate the supervisor and all child processes.


=head1 METHODS

=head2 new

    my $sv = App::Sv->new({ run => {...}, global => {...} });

Creates a supervisor instance with a list of commands to monitor.

It accepts an anonymous hash with the following options:

=over 4

=item run

A hash reference with the commands to execute and monitor. Each command can be
a scalar, or a hash reference.

=item global

A hash reference with the global configuration, such as the control socket.

=back

=head2 run

    $sv->run;

Starts the supervisor, start all the child processes and monitors each one.

This method returns when the supervisor is stopped with either a SIGINT or a
SIGTERM.


=head1 SEE ALSO

L<App::SuperviseMe>
L<AnyEvent>


=cut
