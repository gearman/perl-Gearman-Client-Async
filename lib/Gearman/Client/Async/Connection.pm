package Gearman::Client::Async::Connection;
use strict;
use warnings;

use Danga::Socket;
use base 'Danga::Socket';
use fields (
            'state',       # one of 3 state constants below
            'waiting',     # hashref of $handle -> [ Task+ ]
            'need_handle', # arrayref of Gearman::Task objects which
                           # have been submitted but need handles.
            'parser',      # parser object
            'hostspec',    # scalar: "host:ip"
            'deadtime',    # unixtime we're marked dead until.
            'task2handle', # hashref of stringified Task -> scalar handle
            'on_ready',    # arrayref of on_ready callbacks to run on connect success
            'on_error',    # arrayref of on_error callbacks to run on connect failure
            'options',     # hashref of options associated with this connection and their value
            'requests',    # arrayref of outstanding requests to line up with results or errors
            't_offline',   # bool: fake being off the net for purposes of connecting, to force timeout
            'worker_funcs',# hashref of name -> CODE for worker functions this client supports
            'is_worker',   # bool indicating whether this client acts as a worker
            );

our $T_ON_TIMEOUT;

use constant S_DISCONNECTED => \ "disconnected";
use constant S_CONNECTING   => \ "connecting";
use constant S_READY        => \ "ready";

use Carp qw(croak);
use Gearman::Task;
use Gearman::Util;
use Gearman::Job::Async;
use Scalar::Util qw(weaken);

use IO::Handle;
use Socket qw(PF_INET IPPROTO_TCP TCP_NODELAY SOL_SOCKET SOCK_STREAM SO_ERROR);
use Errno qw(EINPROGRESS EWOULDBLOCK EAGAIN);

sub DEBUGGING () { 0 }

sub new {
    my Gearman::Client::Async::Connection $self = shift;

    my %opts = @_;

    $self = fields::new( $self ) unless ref $self;

    my $hostspec         = delete( $opts{hostspec} ) or
        croak("hostspec required");

    if (ref $hostspec eq 'GLOB') {
        # In this case we have been passed a globref, hopefully a socket that has already
        # been connected to the Gearman server in some way.
        $self->SUPER::new($hostspec);
        $self->{state}       = S_CONNECTING;
        $self->{parser} = Gearman::ResponseParser::Async->new( $self );
        $self->watch_write(1);
    } elsif (ref $hostspec && $hostspec->can("to_inprocess_server")) {
        # In this case we have been passed an object that looks like a Gearman::Server,
        # which we can just call "to_inprocess_server" on to get a socketpair connecting
        # to it.
        my $sock = $hostspec->to_inprocess_server;
        $self->SUPER::new($sock);
        $self->{state}       = S_CONNECTING;
        $self->{parser} = Gearman::ResponseParser::Async->new( $self );
        $self->watch_write(1);
    } else {
        $self->{state}       = S_DISCONNECTED;
    }

    $self->{hostspec}    = $hostspec;
    $self->{waiting}     = {};
    $self->{need_handle} = [];
    $self->{deadtime}    = 0;
    $self->{on_ready}    = [];
    $self->{on_error}    = [];
    $self->{task2handle} = {};
    $self->{options}     = {};
    $self->{requests}    = [];
    $self->{worker_funcs} = {};
    $self->{is_worker} = 0;

    if (my $val = delete $opts{exceptions}) {
        $self->{options}->{exceptions} = $val;
    }

    croak "Unknown parameters: " . join(", ", keys %opts) if %opts;
    return $self;
}

sub as_string {
    my Gearman::Client::Async::Connection $self = shift;

    my $hostspec = $self->{hostspec};

    my $waiting     = $self->{waiting};
    my $need_handle = $self->{need_handle};
    my $requests    = $self->{requests};

    return sprintf("%s(%d,%d,%d)", $hostspec,
        scalar keys %$waiting,
        scalar @$need_handle,
        scalar @$requests,
    );
}

sub close_when_finished {
    my Gearman::Client::Async::Connection $self = shift;
    # FIXME: implement
}

sub hostspec {
    my Gearman::Client::Async::Connection $self = shift;

    return $self->{hostspec};
}

sub connect {
    my Gearman::Client::Async::Connection $self = shift;

    $self->{state} = S_CONNECTING;

    my ($host, $port) = split /:/, $self->{hostspec}; # /
    $port ||= 7003;

    warn "Connecting to $self->{hostspec}\n" if DEBUGGING;

    socket my $sock, PF_INET, SOCK_STREAM, IPPROTO_TCP;
    IO::Handle::blocking($sock, 0);
    setsockopt($sock, IPPROTO_TCP, TCP_NODELAY, pack("l", 1)) or die;

    unless ($sock && defined fileno($sock)) {
        warn( "Error creating socket: $!\n" );
        return undef;
    }

    $self->SUPER::new( $sock );
    $self->{parser} = Gearman::ResponseParser::Async->new( $self );

    my $rv = eval {
        connect $sock, Socket::sockaddr_in($port, Socket::inet_aton($host));
    };
    if ($@) {
        $self->on_connect_error;
        return;
    } elsif (!$rv) {
        unless ($! == EINPROGRESS || $! == EWOULDBLOCK || $! == EAGAIN || $! == 0) {
            warn "Error on connect: $!\n" if DEBUGGING;
            $self->on_connect_error;
        }
    }

    Danga::Socket->AddTimer(0.25, sub {
        return unless $self->{state} == S_CONNECTING;
        $T_ON_TIMEOUT->() if $T_ON_TIMEOUT;
        $self->on_connect_error;
    });

    # unless we're faking being offline for the test suite, connect and watch
    # for writabilty so we know the connect worked...
    unless ($self->{t_offline}) {
        $self->watch_write(1);
    }
}

sub event_write {
    my Gearman::Client::Async::Connection $self = shift;

    if ($self->{state} == S_CONNECTING) {
        if (my $error = unpack('i', getsockopt($self->{sock}, SOL_SOCKET, SO_ERROR))) {
            local $! = $error;
            warn "Error during write state after connect: $!\n" if DEBUGGING;
            $self->on_connect_error;
            return;
        }
        $self->{state} = S_READY;
        $self->watch_read(1);
        warn "$self->{hostspec} connected and ready.\n" if DEBUGGING;
        $_->() foreach @{$self->{on_ready}};
        $self->destroy_callbacks;

        my $options = $self->{options};
        my $requests = $self->{requests};

        foreach my $option (keys %$options) {
            my $req = Gearman::Util::pack_req_command("option_req", $option);
            $self->write($req);
            push @$requests, $option;
        }
    }

    $self->watch_write(0) if $self->write(undef);
}

sub destroy_callbacks {
    my Gearman::Client::Async::Connection $self = shift;
    $self->{on_ready} = [];
    $self->{on_error} = [];
}

sub event_read {
    my Gearman::Client::Async::Connection $self = shift;

    my $input = $self->read( 128 * 1024 );
    unless (defined $input) {
        $self->mark_dead if $self->stuff_outstanding;
        $self->close( "EOF" );
        return;
    }

    $self->{parser}->parse_data( $input );
}

sub event_err {
    my Gearman::Client::Async::Connection $self = shift;

    my $was_connecting = ($self->{state} == S_CONNECTING);

    if ($was_connecting && $self->{t_offline}) {
        $self->SUPER::close( "error" );
        return;
    }

    $self->mark_dead;
    $self->close( "error" );
    $self->on_connect_error if $was_connecting;
}

sub on_connect_error {
    my Gearman::Client::Async::Connection $self = shift;
    warn "Jobserver, $self->{hostspec} ($self) has failed to connect properly\n" if DEBUGGING;

    $self->mark_dead;
    $self->close( "error" );
    $_->() foreach @{$self->{on_error}};
    $self->destroy_callbacks;
}

sub close {
    my Gearman::Client::Async::Connection $self = shift;
    my $reason = shift;

    if ($self->{state} != S_DISCONNECTED) {
        $self->{state} = S_DISCONNECTED;
        $self->SUPER::close( $reason );
    }

    $self->_requeue_all;
}

sub mark_dead {
    my Gearman::Client::Async::Connection $self = shift;
    $self->{deadtime} = time + 10;
    warn "$self->{hostspec} marked dead for a bit." if DEBUGGING;
}

sub alive {
    my Gearman::Client::Async::Connection $self = shift;
    return $self->{deadtime} <= time;
}

sub add_task {
    my Gearman::Client::Async::Connection $self = shift;
    my Gearman::Task $task = shift;

    Carp::confess("add_task called when in wrong state")
        unless $self->{state} == S_READY;

    warn "writing task $task to $self->{hostspec}\n" if DEBUGGING;

    $self->write( $task->pack_submit_packet );
    push @{$self->{need_handle}}, $task;
    Scalar::Util::weaken($self->{need_handle}->[-1]);
}

sub register_function {
    my Gearman::Client::Async::Connection $self = shift;
    my $func_name = shift;
    my $code = shift;

    warn "Registered worker function $func_name\n" if DEBUGGING;

    $self->{worker_funcs}{$func_name} = $code;

    my $req = Gearman::Util::pack_req_command("can_do", $func_name);
    $self->write( $req );

    $self->start_worker();

}

sub start_worker {
    my Gearman::Client::Async::Connection $self = shift;

    unless ($self->{is_worker}) {
        warn "Becoming a worker\n" if DEBUGGING;
        $self->{is_worker} = 1;
        $self->request_job();
    }
}

sub request_job {
    my Gearman::Client::Async::Connection $self = shift;

    warn "Requesting a job\n" if DEBUGGING;
    my $req = Gearman::Util::pack_req_command("grab_job");
    $self->write( $req );
}

sub announce_sleep {
    my Gearman::Client::Async::Connection $self = shift;

    warn "Telling server that our worker is sleeping\n" if DEBUGGING;
    my $req = Gearman::Util::pack_req_command("pre_sleep");
    $self->write( $req );
}

sub announce_job_status {
    my Gearman::Client::Async::Connection $self = shift;
    my $job_handle = shift;
    my $nu = shift;
    my $de = shift;

    warn "Job $job_handle has status $nu/$de\n" if DEBUGGING;

    my $arg = join("\0", $job_handle, $nu, $de);
    my $req = Gearman::Util::pack_req_command("work_status", $arg);
    $self->write( $req );
}

sub announce_job_complete {
    my Gearman::Client::Async::Connection $self = shift;
    my $job_handle = shift;
    my $ret_ref = shift;

    warn "Job $job_handle completed successfully\n" if DEBUGGING;

    my $arg = join("\0", $job_handle, $$ret_ref);
    my $req = Gearman::Util::pack_req_command("work_complete", $arg);
    $self->write( $req );
}

sub announce_job_fail {
    my Gearman::Client::Async::Connection $self = shift;
    my $job_handle = shift;

    warn "Job $job_handle failed\n" if DEBUGGING;

    my $req = Gearman::Util::pack_req_command("work_fail", $job_handle);
    $self->write( $req );
}

sub is_worker {
    my Gearman::Client::Async::Connection $self = shift;

    return $self->{is_worker};
}

sub stuff_outstanding {
    my Gearman::Client::Async::Connection $self = shift;
    return
        @{$self->{on_ready}} ||
        @{$self->{on_error}} ||
        @{$self->{need_handle}} ||
        %{$self->{waiting}};
}

sub _requeue_all {
    my Gearman::Client::Async::Connection $self = shift;

    my $need_handle = $self->{need_handle};
    my $waiting     = $self->{waiting};

    $self->{need_handle} = [];
    $self->{waiting}     = {};

    while (@$need_handle) {
        my $task = shift @$need_handle;
        warn "Task $task in need_handle queue during socket error, queueing for redispatch\n" if DEBUGGING;
        $task->fail if $task;
    }

    while (my ($shandle, $tasklist) = each( %$waiting )) {
        foreach my $task (@$tasklist) {
            warn "Task $task ($shandle) in waiting queue during socket error, queueing for redispatch\n" if DEBUGGING;
            $task->fail;
        }
    }
}

sub process_packet {
    my Gearman::Client::Async::Connection $self = shift;
    my $res = shift;

    warn "Got packet '$res->{type}' from $self->{hostspec}\n" if DEBUGGING;

    if ($res->{type} eq "job_created") {

        die "Um, got an unexpected job_created notification" unless @{ $self->{need_handle} };
        my Gearman::Task $task = shift @{ $self->{need_handle} } or
            return 1;


        my $shandle = ${ $res->{'blobref'} };
        if ($task) {
            $self->{task2handle}{"$task"} = $shandle;
            push @{ $self->{waiting}->{$shandle} ||= [] }, $task;
        }
        return 1;
    }

    if ($res->{type} eq "work_fail") {
        my $shandle = ${ $res->{'blobref'} };
        warn "Job failure: $shandle\n" if DEBUGGING;
        $self->_fail_jshandle($shandle);
        return 1;
    }

    if ($res->{type} eq "work_complete") {
        ${ $res->{'blobref'} } =~ s/^(.+?)\0//
            or die "Bogus work_complete from server";
        my $shandle = $1;

        my $task_list = $self->{waiting}{$shandle} or
            return;

        my Gearman::Task $task = shift @$task_list or
            return;

        $task->complete($res->{'blobref'});

        unless (@$task_list) {
            delete $self->{waiting}{$shandle};
            delete $self->{task2handle}{"$task"};
        }

        warn "Jobs: " . scalar( keys( %{$self->{waiting}} ) ) . "\n" if DEBUGGING;

        return 1;
    }

    if ($res->{type} eq "work_status") {
        my ($shandle, $nu, $de) = split(/\0/, ${ $res->{'blobref'} });

        my $task_list = $self->{waiting}{$shandle} or
            return;

        foreach my Gearman::Task $task (@$task_list) {
            $task->status($nu, $de);
        }

        return 1;
    }

    if ($res->{type} eq "work_exception") {
        ${ $res->{'blobref'} } =~ s/^(.+?)\0//
            or die "Bogus work_complete from server";
        my $shandle = $1;


        my $task_list = $self->{waiting}{$shandle} or
            return;

        my Gearman::Task $task = $task_list->[0] or
            return;

        $task->exception($res->{'blobref'});

        return 1;
    }

    if ($res->{type} eq "error") {
        my $requests = $self->{requests};

        if (@$requests) {
            my $request = shift @$requests;
            delete $self->{options}->{$request};
            warn "Request for option '$request' failed. Removing option\n" if DEBUGGING;
            return 1;
        }
    }

    if ($res->{type} eq "option_res") {
        my $requests = $self->{requests};

        if (@$requests) {
            my $request = shift @$requests;
            warn "Request for option '$request' success.\n" if DEBUGGING;
            return 1;
        }
    }

    if ($self->is_worker) {

        if ($res->{type} eq 'no_job') {
            warn "No job for us to do.\n" if DEBUGGING;
            # Go to sleep.
            $self->announce_sleep();
            return 1;
        }

        if ($res->{type} eq 'job_assign') {
            ${ $res->{'blobref'} } =~ s/^(.+?)\0(.+?)\0// or die "Uh, regexp on job_assign failed";
            my ($handle, $func) = ($1, $2);
            my $code = $self->{worker_funcs}{$func};

            warn "Assigned job $handle for function $func\n" if DEBUGGING;

            if ($code) {
                my $job = Gearman::Job::Async->new($func, $res->{'blobref'}, $handle, $self);
                warn "Calling handler for $func...\n" if DEBUGGING;
                $code->($job);
            }
            else {
                warn "I don't know how to handle the function $func\n" if DEBUGGING;

                # Job server has given us a job we can't handle, so fail.
                $self->announce_job_fail($handle);
            }

            # While we're handling that job we can also handle additional jobs,
            # since the job must be async.
            $self->request_job();

            return 1;
        }

        if ($res->{type} eq 'noop') {
            # Assume we've just been woken up from sleep to perform work.
            warn "Recieved no-op request. Waking up.\n" if DEBUGGING;
            $self->request_job();

            return 1;
        }

    }

    die "Unknown/unimplemented packet type: $res->{type}";

}

sub give_up_on {
    my Gearman::Client::Async::Connection $self = shift;
    my $task = shift;

    my $shandle = $self->{task2handle}{"$task"} or return;
    my $task_list = $self->{waiting}{$shandle} or return;
    @$task_list = grep { $_ != $task } @$task_list;
    unless (@$task_list) {
        delete $self->{waiting}{$shandle};
    }

}

# note the failure of a task given by its jobserver-specific handle
sub _fail_jshandle {
    my Gearman::Client::Async::Connection $self = shift;
    my $shandle = shift;

    my $task_list = $self->{waiting}->{$shandle} or
        return;

    my Gearman::Task $task = shift @$task_list or
        return;

    # cleanup
    unless (@$task_list) {
        delete $self->{task2handle}{"$task"};
        delete $self->{waiting}{$shandle};
    }

    $task->fail;
}

sub get_in_ready_state {
    my ($self, $on_ready, $on_error) = @_;

    if ($self->{state} == S_READY) {
        $on_ready->();
        return;
    }

    push @{$self->{on_ready}}, $on_ready if $on_ready;
    push @{$self->{on_error}}, $on_error if $on_error;

    $self->connect if $self->{state} == S_DISCONNECTED;
}

sub t_set_offline {
    my ($self, $val) = @_;
    $val = 1 unless defined $val;
    $self->{t_offline} = $val;
}

package Gearman::ResponseParser::Async;

use strict;
use warnings;
use Scalar::Util qw(weaken);

use Gearman::ResponseParser;
use base 'Gearman::ResponseParser';

sub new {
    my $class = shift;

    my $self = $class->SUPER::new;

    $self->{_conn} = shift;
    weaken($self->{_conn});

    return $self;
}

sub on_packet {
    my $self = shift;
    my $packet = shift;

    return unless $self->{_conn};
    $self->{_conn}->process_packet( $packet );
}

sub on_error {
    my $self = shift;

    return unless $self->{_conn};
    $self->{_conn}->mark_unsafe;
    $self->{_conn}->close;
}

1;
