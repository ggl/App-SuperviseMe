package App::Sv;

# ABSTRACT: Simple process supervisor
# VERSION
# AUTHORITY

use strict;
use warnings;
use Carp 'croak';
use AnyEvent;
use AnyEvent::Socket;
use Data::Dumper;


# Constructors
sub new {
	my ($class, $conf) = @_;
	
	my $run = $conf->{run};
	croak "Commands must be passed as a HASH ref" unless ref($run) eq 'HASH';
	croak "Missing command list" unless scalar (keys %$run) > 0;
	
	# set default options
	foreach my $cmd (keys %$run) {
		$run->{$cmd} = {
			cmd => $run->{$cmd},
			start_delay => 1,
			start_retries => 10,
			stop_delay => 1,
			stop_retries => 1,
			stop_signal => 'TERM',
			reload_signal => 'HUP'
		} unless ref($run->{$cmd}) eq 'HASH';
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

	if ($cmd->{start_count}) {
		$cmd->{start_count}++;
	}
	else {
		$cmd->{start_count} = 1;
	}
	_debug("Starting '$cmd->{cmd}' attempt $cmd->{start_count}");
	
	my $pid = fork();
	if (!defined $pid) {
		_debug("fork() failed: $!");
		$self->_restart_cmd($cmd);
		return;
	}

	# child
	if ($pid == 0) {
		$cmd = $cmd->{cmd};
		_debug("Executing '$cmd'");
		exec($cmd);
		exit(1);
	}

	# parent
	_debug("Watching pid $pid for '$cmd->{cmd}'");
	$cmd->{pid} = $pid;
	$cmd->{watcher} = AE::child $pid, sub { $self->_child_exited($cmd, @_) };
	delete $cmd->{start_count} if defined $pid;
	
	return $pid;
}

sub _child_exited {
	my ($self, $cmd, undef, $status) = @_;
	
	_debug("Child $cmd->{pid} exited, status $status: '$cmd->{cmd}'");
	delete $cmd->{watcher};
	delete $cmd->{pid};
	$cmd->{last_status} = $status >> 8;
	$self->_restart_cmd($cmd);
}

sub _restart_cmd {
	my ($self, $cmd) = @_;

	return if ($cmd->{start_retries} && $cmd->{start_count} && 
		($cmd->{start_count} >= $cmd->{start_retries}));
	
	_debug("Restarting '$cmd->{cmd}' in $cmd->{start_delay} seconds");
	my $t;
	$t = AE::timer $cmd->{start_delay}, 0, sub {
		$self->_start_cmd($cmd);
		undef $t;
	};
}

sub _stop_cmd {
	my ($self, $cmd) = @_;
	
	_debug("Sent signal $cmd->{stop_signal} to $cmd->{pid}");
	my $st = kill($cmd->{stop_signal}, $cmd->{pid});
	map { delete $cmd->{$_} } (qw(watcher pid start_count)) if $st;
	
	return $st;
}

sub _signal_cmd {
	my ($self, $cmd, $signal) = @_;
	
	return unless ($cmd->{pid} && $signal);
	_debug("Sent signal $signal to $cmd->{pid}");
	my $st = kill($signal, $cmd->{pid});
	
	return $st;
}

sub _signal_all_cmds {
	my ($self, $signal, $cv) = @_;
	
	_debug("Received signal $signal");
	my $is_any_alive = 0;
	foreach my $key (keys %{ $self->{run} }) {
		my $cmd = $self->{run}->{$key};
		next unless my $pid = $cmd->{pid};
		_debug("... sent signal $signal to $pid");
		$is_any_alive++;
		kill($signal, $pid);
	}

	return if $cv and $is_any_alive;

	_debug('Exiting...');
	$cv->send if $cv;
}

# Contolling socket listener
sub _listener {
	my $self = shift;
	
	my ($host, $port) = parse_hostport($self->{conf}->{listen});
	$self->{server} = tcp_server $host, $port,
	sub { $self->_client_conn(@_) },
	sub {
		my ($fh, $host, $port) = @_;
		_debug("Listener bound to $host:$port");
	};
}

# Accept a new conenction
sub _client_conn {
	my ($self, $fh, $host, $port) = @_;
	
	_debug("Connection from $host:$port");
	return unless $fh;
	
	$self->_status($fh);
	$self->_client_input($fh);
	
	return $fh;
}

# Client input
sub _client_input {
	my ($self, $fh) = @_;
	
	my $rw; $rw = AE::io $fh, 0,
	sub {
		while(defined(my $ln = <$fh>)) {
			chomp $ln;
			# root commands
			if ($ln =~ /^(\.|quit)$/) {
				undef $rw;
			}
			elsif ($ln eq 'status') {
				$self->_status($fh);
			}
			else {
				my ($cmd, $sw) = split(' ', $ln);
				if ($cmd && $sw) {
					my $st;
					$cmd = $self->{run}->{$cmd} if $self->{run}->{$cmd};
					# control commands
					if ($sw =~ /^(down|stop)$/) {
						$st = $self->_stop_cmd($cmd) if $cmd->{pid};
					}
					elsif ($sw =~ /^(up|start)$/) {
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
					## response
					$st = $st ? $st : "fail";
					syswrite($fh, "$ln $st\n") if $st;
					undef $st;
				}
			}
		}
	};
}

# Commands status
sub _status {
	my ($self, $fh) = @_;
	
	return unless $fh;
	foreach my $cmd (keys %{ $self->{run} }) {
		my $name = $cmd;
		$cmd = $self->{run}->{$cmd};
		if ($cmd->{pid}) {
			syswrite($fh, "$name up $cmd->{pid}\n");
		}
		elsif ($cmd->{start_count}) {
			syswrite($fh, "$name fail $cmd->{start_count}\n");
		}
		else {
			syswrite($fh, "$name down\n");
		}
	}
}

# Loggers

sub _out {
	return unless -t \*STDOUT && -t \*STDIN;
	print @_, "\n";
}

sub _debug {
	return unless $ENV{SV_DEBUG};
	print STDERR "DEBUG [$$] ", @_, "\n";
}

sub _error {
	print "ERROR: ", @_, "\n";
	return;
}

1;

__END__

=encoding utf8

=head1 SYNOPSIS

    my $sv = App::Sv->new(
        cmds => [
          'plackup -p 3010 ./sites/x/app.psgi',
          'plackup -p 3011 ./sites/y/app.psgi',
          ['bash', '-c', '... bash script ...'],
        ],
    );
    $superviser->run;


=head1 DESCRIPTION

This module implements a multi-process supervisor.

It takes a list of commands to execute and starts each one, and then monitors
their execution. If one of the program dies, the supervisor will restart it
after a small 1 second pause.

You can send SIGTERM to the supervisor process to kill all childs and exit.

You can also send SIGINT (Ctrl-C on your terminal) to restart the processes. If
a second SIGINT is received and no child process is currently running, the
supervisor will exit. This allows you to tap Ctrl- C twice in quick succession
in a terminal window to terminate the supervisor and all child processes


=head1 METHODS

=head2 new

    my $supervisor = App::SuperviseMe->new( cmds => [...]);

Creates a supervisor instance with a list of commands to monitor.

It accepts a hash with the following options:

=over 4

=item cmds

A list reference with the commands to execute and monitor. Each command can be
a scalar, or a list reference.

=back


=head2 new_from_options

    my $supervisor = App::SuperviseMe->new_from_options;

Reads the list of commands to start and monitor from C<STDIN>. It strips
white-space from the beggining and end of the line, and skips lines that start
with a C<#>.

Returns the superviser object.


=head2 run

    $supervisor->run;

Starts the supervisor, start all the child processes and monitors each one.

This method returns when the supervisor is stopped with either a SIGINT or a
SIGTERM.


=head1 SEE ALSO

L<AnyEvent>


=cut
