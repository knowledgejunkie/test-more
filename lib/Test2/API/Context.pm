package Test2::API::Context;
use strict;
use warnings;

use Carp qw/confess croak longmess/;
use Test2::Util qw/get_tid try pkg_to_file/;

use Test2::Util::Trace();
use Test2::API();

# Preload some key event types
my %LOADED = (
    map {
        my $pkg  = "Test2::Event::$_";
        my $file = "Test2/Event/$_.pm";
        require $file unless $INC{$file};
        ( $pkg => $pkg, $_ => $pkg )
    } qw/Ok Diag Note Plan Bail Exception Waiting Skip Subtest/
);

use Test2::Util::ExternalMeta qw/meta get_meta set_meta delete_meta/;
use Test2::Util::HashBase qw{
    stack hub trace _on_release _depth _canon_count aborted
    errno eval_error child_error
};

# Private, not package vars
# It is safe to cache these.
my $ON_RELEASE = Test2::API::_context_release_callbacks_ref();
my $CONTEXTS   = Test2::API::_contexts_ref();

sub init {
    my $self = shift;

    confess "The 'trace' attribute is required"
        unless $self->{+TRACE};

    confess "The 'hub' attribute is required"
        unless $self->{+HUB};

    $self->{+_DEPTH} = 0 unless defined $self->{+_DEPTH};

    $self->{+ERRNO}       = $! unless exists $self->{+ERRNO};
    $self->{+EVAL_ERROR}  = $@ unless exists $self->{+EVAL_ERROR};
    $self->{+CHILD_ERROR} = $? unless exists $self->{+CHILD_ERROR};
}

sub snapshot { bless {%{$_[0]}, _canon_count => undef}, __PACKAGE__ }

sub restore_error_vars {
    my $self = shift;
    ($!, $@, $?) = @$self{+ERRNO, +EVAL_ERROR, +CHILD_ERROR};
}

# release exists to implement behaviors like die-on-fail. In die-on-fail you
# want to die after a failure, but only after diagnostics have been reported.
# The ideal time for the die to happen is when the context is released.
# Unfortunately die does not work in a DESTROY block.
sub release {
    my ($self) = @_;

    croak "release() should not be called on a non-canonical context"
        unless $self->{+_CANON_COUNT};

    return if --($self->{+_CANON_COUNT});

    my $hub = $self->{+HUB};
    my $hid = $hub->{hid};

    croak "context thinks it is canon, but it is not"
        unless $CONTEXTS->{$hid} && $CONTEXTS->{$hid} == $self;

    # Remove the key itself to avoid a slow memory leak
    delete $CONTEXTS->{$hid};

    if (my $cbk = $self->{+_ON_RELEASE}) {
        $_->($self) for reverse @$cbk;
    }
    if (my $hcbk = $hub->{_context_release}) {
        $_->($self) for reverse @$hcbk;
    }
    $_->($self) for reverse @$ON_RELEASE;

    # Do this last so that nothing else changes them.
    ($!, $@, $?) = @$self{+ERRNO, +EVAL_ERROR, +CHILD_ERROR};

    return;
}

sub do_in_context {
    my $self = shift;
    my ($sub, @args) = @_;

    # We need to update the pid/tid and error vars.
    my $clone = $self->snapshot;
    @$clone{+ERRNO, +EVAL_ERROR, +CHILD_ERROR} = ($!, $@, $?);
    $clone->{+TRACE} = $clone->{+TRACE}->snapshot;
    $clone->{+TRACE}->set_pid($$);
    $clone->{+TRACE}->set_tid(get_tid());

    my $hub = $clone->{+HUB};
    my $hid = $hub->hid;

    my $old = $CONTEXTS->{$hid};

    $clone->{+_CANON_COUNT} = 1;
    $CONTEXTS->{$hid} = $clone;
    my ($ok, $err) = &try($sub, @args);
    my ($rok, $rerr) = try { $clone->release };
    delete $clone->{+_CANON_COUNT};

    if ($old) {
        $CONTEXTS->{$hid} = $old;
    }
    else {
        delete $CONTEXTS->{$hid};
    }

    die $err  unless $ok;
    die $rerr unless $rok;
}

sub done_testing {
    my $self = shift;
    $self->hub->finalize($self->trace, 1);
    return;
}

sub throw {
    my ($self, $msg) = @_;
    $self->{+ABORTED} = 1;
    $self->release if $self->{+_CANON_COUNT};
    $self->trace->throw($msg);
}

sub alert {
    my ($self, $msg) = @_;
    $self->trace->alert($msg);
}

sub send_event {
    my $self  = shift;
    my $event = shift;
    my %args  = @_;

    my $pkg = $LOADED{$event} || $self->_parse_event($event);

    $self->{+HUB}->send(
        $pkg->new(
            trace => $self->{+TRACE}->snapshot,
            %args,
        )
    );
}

sub build_event {
    my $self  = shift;
    my $event = shift;
    my %args  = @_;

    my $pkg = $LOADED{$event} || $self->_parse_event($event);

    $pkg->new(
        trace => $self->{+TRACE}->snapshot,
        %args,
    );
}

sub ok {
    my $self = shift;
    my ($pass, $name, $diag) = @_;

    my $hub = $self->{+HUB};

    my $e = bless {
        trace => bless( {%{$self->{+TRACE}}}, 'Test2::Util::Trace'),
        pass  => $pass,
        name  => $name,
    }, 'Test2::Event::Ok';
    $e->init;

    $hub->send($e);
    return $e if $pass;

    $self->failure_diag($e);

    if ($diag && @$diag) {
        $self->diag($_) for @$diag
    }

    return $e;
}

sub failure_diag {
    my $self = shift;
    my ($e) = @_;

    # This behavior is inherited from Test::Builder which injected a newline at
    # the start of the first diagnostics when the harness is active, but not
    # verbose. This is important to keep the diagnostics from showing up
    # appended to the existing line, which is hard to read. In a verbose
    # harness there is no need for this.
    my $prefix = $ENV{HARNESS_ACTIVE} && !$ENV{HARNESS_IS_VERBOSE} ? "\n" : "";

    # Figure out the debug info, this is typically the file name and line
    # number, but can also be a custom message. If no trace object is provided
    # then we have nothing useful to display.
    my $name  = $e->name;
    my $trace = $e->trace;
    my $debug = $trace ? $trace->debug : "[No trace info available]";

    # Create the initial diagnostics. If the test has a name we put the debug
    # info on a second line, this behavior is inherited from Test::Builder.
    my $msg = defined($name)
        ? qq[${prefix}Failed test '$name'\n$debug.\n]
        : qq[${prefix}Failed test $debug.\n];

    $self->diag($msg);
}

sub skip {
    my $self = shift;
    my ($name, $reason, @extra) = @_;
    $self->send_event(
        'Skip',
        name => $name,
        reason => $reason,
        pass => 1,
        @extra,
    );
}

sub note {
    my $self = shift;
    my ($message) = @_;
    $self->send_event('Note', message => $message);
}

sub diag {
    my $self = shift;
    my ($message) = @_;
    my $hub = $self->{+HUB};
    $self->send_event(
        'Diag',
        message => $message,
    );
}

sub plan {
    my ($self, $max, $directive, $reason) = @_;
    $self->{+ABORTED} = 1 if $directive && $directive =~ m/^(SKIP|skip_all)$/;
    $self->send_event('Plan', max => $max, directive => $directive, reason => $reason);
}

sub bail {
    my ($self, $reason) = @_;
    $self->{+ABORTED} = 1;
    $self->send_event('Bail', reason => $reason);
}

sub _parse_event {
    my $self = shift;
    my $event = shift;

    my $pkg;
    if ($event =~ m/^\+(.*)/) {
        $pkg = $1;
    }
    else {
        $pkg = "Test2::Event::$event";
    }

    unless ($LOADED{$pkg}) {
        my $file = pkg_to_file($pkg);
        my ($ok, $err) = try { require $file };
        $self->throw("Could not load event module '$pkg': $err")
            unless $ok;

        $LOADED{$pkg} = $pkg;
    }

    confess "'$pkg' is not a subclass of 'Test2::Event'"
        unless $pkg->isa('Test2::Event');

    $LOADED{$event} = $pkg;

    return $pkg;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::API::Context - Object to represent a testing context.

=head1 EXPERIMENTAL RELEASE

This is an experimental release. Using this right now is not recommended.

=head1 DESCRIPTION

The context object is the primary interface for authors of testing tools
written with L<Test2>. The context object represents the context in
which a test takes place (File and Line Number), and provides a quick way to
generate events from that context. The context object also takes care of
sending events to the correct L<Test2::Hub> instance.

=head1 SYNOPSIS

In general you will not be creating contexts directly. To obtain a context you
should always use C<context()> which is exported by the L<Test2> module.

    use Test2::API qw/context/;

    sub my_ok {
        my ($bool, $name) = @_;
        my $ctx = context();
        $ctx->ok($bool, $name);
        $ctx->release; # You MUST do this!
        return $bool;
    }

Context objects make it easy to wrap other tools that also use context. Once
you grab a context, any tool you call before releasing your context will
inherit it:

    sub wrapper {
        my ($bool, $name) = @_;
        my $ctx = context();
        $ctx->diag("wrapping my_ok");

        my $out = my_ok($bool, $name);
        $ctx->release; # You MUST do this!
        return $out;
    }

=head1 CRITICAL DETAILS

=over 4

=item you MUST always use the context() sub from Test2::API

Creating your own context via C<< Test2::API::Context->new() >> will almost never
produce a desirable result. Use C<context()> which is exported by L<Test2>.

There are a handful of cases where a tool author may want to create a new
congtext by hand, which is why the C<new> method exists. Unless you really know
what you are doing you should avoid this.

=item You MUST always release the context when done with it

Releasing the context tells the system you are done with it. This gives it a
chance to run any necessary callbacks or cleanup tasks. If you forget to
release the context it will try to detect the problem and warn you about it.

=item You MUST NOT pass context objects around

When you obtain a context object it is made specifically for your tool and any
tools nested within. If you pass a context around you run the risk of polluting
other tools with incorrect context information.

If you are certain that you want a different tool to use the same context you
may pass it a snapshot. C<< $ctx->snapshot >> will give you a shallow clone of
the context that is safe to pass around or store.

=item You MUST NOT store or cache a context for later

As long as a context exists for a given hub, all tools that try to get a
context will get the existing instance. If you try to store the context you
will pollute other tools with incorrect context information.

If you are certain that you want to save the context for later, you can use a
snapshot. C<< $ctx->snapshot >> will give you a shallow clone of the context
that is safe to pass around or store.

C<context()> has some mechanisms to protect you if you do cause a context to
persist beyond the scope in which it was obtained. In practice you should not
rely on these protections, and they are fairly noisy with warnings.

=item You SHOULD obtain your context as soon as possible in a given tool

You never know what tools you call from within your own tool will need a
context. Obtaining the context early ensures that nested tools can find the
context you want them to find.

=back

=head1 METHODS

=over 4

=item $ctx->done_testing;

Note that testing is finished. If no plan has been set this will generate a
Plan event.

=item $clone = $ctx->snapshot()

This will return a shallow clone of the context. The shallow clone is safe to
store for later.

=item $ctx->release()

This will release the context. This runs cleanup tasks, and several important
hooks. It will also restore C<$!>, C<$?>, and C<$@> to what they were when the
context was created.

B<Note:> If a context is aquired more than once an internal refcount is kept.
C<release()> decrements the ref count, none of the other actions of
C<release()> will occur unless the refcount hits 0. This means only the last
call to C<release()> will reset C<$?>, C<$!>, C<$@>,and run the cleanup tasks.

=item $ctx->throw($message)

This will throw an exception reporting to the file and line number of the
context. This will also release the context for you.

=item $ctx->alert($message)

This will issue a warning from the file and line number of the context.

=item $stack = $ctx->stack()

This will return the L<Test2::API::Stack> instance the context used to find
the current hub.

=item $hub = $ctx->hub()

This will return the L<Test2::Hub> instance the context recognises as
the current one to which all events should be sent.

=item $dbg = $ctx->trace()

This will return the L<Test2::Util::Trace> instance used by the context.

=item $ctx->do_in_context(\&code, @args);

Sometimes you have a context that is not current, and you want things to use it
as the current one. In these cases you can call
L<< $ctx->do_in_context(sub { ... }) >>. The codeblock will be run, and
anything inside of it that looks for a context will find the one on which the
method was called.

This B<DOES NOT> effect context on other hubs, only the hub used by the context
will be effected.

    my $ctx = ...;
    $ctx->do_in_context(sub {
        my $ctx = context(); # returns the $ctx the sub is called on
    });

B<Note:> The context will actually be cloned, the clone will be used instead of
the original. This allows the TID, PID, and error vars to be correct without
modifying the original context.

=item $ctx->restore_error_vars()

This will set C<$!>, C<$?>, and C<$@> to what they were when the context was
created. There is no localization or anything done here, calling this method
will actually set these vars.

=item $! = $ctx->errno()

The (numeric) value of C<$!> when the context was created.

=item $? = $ctx->child_error()

The value of C<$?> when the context was created.

=item $@ = $ctx->eval_error()

The value of C<$@> when the context was created.

=back

=head2 EVENT PRODUCTION METHODS

=over 4

=item $event = $ctx->ok($bool, $name)

=item $event = $ctx->ok($bool, $name, \@diag)

This will create an L<Test2::Event::Ok> object for you. If C<$bool> is false
then an L<Test2::Event::Diag> event will be sent as well with details about the
failure. If you do not want automatic diagnostics you should use the
C<send_event()> method directly.

The C<\@diag> can contain diagnostics messages you wish to have displayed in the
event of a failure. For a passing test the diagnostics array will be ignored.

=item $event = $ctx->note($message)

Send an L<Test2::Event::Note>. This event prints a message to STDOUT.

=item $event = $ctx->diag($message)

Send an L<Test2::Event::Diag>. This event prints a message to STDERR.

=item $event = $ctx->plan($max)

=item $event = $ctx->plan(0, 'SKIP', $reason)

This can be used to send an L<Test2::Event::Plan> event. This event
usually takes either a number of tests you expect to run. Optionally you can
set the expected count to 0 and give the 'SKIP' directive with a reason to
cause all tests to be skipped.

=item $event = $ctx->skip($name, $reason);

Send an L<Test2::Event::Skip> event.

=item $event = $ctx->bail($reason)

This sends an L<Test2::Event::Bail> event. This event will completely
terminate all testing.

=item $event = $ctx->send_event($Type, %parameters)

This lets you build and send an event of any type. The C<$Type> argument should
be the event package name with C<Test2::Event::> left off, or a fully
qualified package name prefixed with a '+'. The event is returned after it is
sent.

    my $event = $ctx->send_event('Ok', ...);

or

    my $event = $ctx->send_event('+Test2::Event::Ok', ...);

=item $event = $ctx->build_event($Type, %parameters)

This is the same as C<send_event()>, except it builds and returns the event
without sending it.

=back

=head1 HOOKS

There are 2 types of hooks, init hooks, and release hooks. As the names
suggest, these hooks are triggered when contexts are created or released.

=head2 INIT HOOKS

These are called whenever a context is initialized. That means when a new
instance is created. These hooks are B<NOT> called every time something
requests a context, just when a new one is created.

=head3 GLOBAL

This is how you add a global init callback. Global callbacks happen for every
context for any hub or stack.

    Test2::API::test2_add_callback_context_init(sub {
        my $ctx = shift;
        ...
    });

=head3 PER HUB

This is how you add an init callback for all contexts created for a given hub.
These callbacks will not run for other hubs.

    $hub->add_context_init(sub {
        my $ctx = shift;
        ...
    });

=head3 PER CONTEXT

This is how you specify an init hook that will only run if your call to
C<context()> generates a new context. The callback will be ignored if
C<context()> is returning an existing context.

    my $ctx = context(on_init => sub {
        my $ctx = shift;
        ...
    });

=head2 RELEASE HOOKS

These are called whenever a context is released. That means when the last
reference to the instance is about to be destroyed. These hooks are B<NOT>
called every time C<< $ctx->release >> is called.

=head3 GLOBAL

This is how you add a global release callback. Global callbacks happen for every
context for any hub or stack.

    Test2::API::test2_add_callback_context_release(sub {
        my $ctx = shift;
        ...
    });

=head3 PER HUB

This is how you add a release callback for all contexts created for a given
hub. These callbacks will not run for other hubs.

    $hub->add_context_release(sub {
        my $ctx = shift;
        ...
    });

=head3 PER CONTEXT

This is how you add release callbacks directly to a context. The callback will
B<ALWAYS> be added to the context that gets returned, it does not matter if a
new one is generated, or if an existing one is returned.

    my $ctx = context(on_release => sub {
        my $ctx = shift;
        ...
    });

=head1 THIRD PARTY META-DATA

This object consumes L<Test2::Util::ExternalMeta> which provides a consistent
way for you to attach meta-data to instances of this class. This is useful for
tools, plugins, and other extentions.

=head1 SOURCE

The source code repository for Test2 can be found at
F<http://github.com/Test-More/Test2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=item Kent Fredric E<lt>kentnl@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2015 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
