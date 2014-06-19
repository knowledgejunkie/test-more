package Test::Builder::Result;
use strict;
use warnings;

use Carp qw/confess/;
use Scalar::Util qw/blessed/;

sub _accessors {
    my $package = caller;
    for my $accessor (@_) {
        my $code = sub {
            my $self = shift;
    
            confess "Method '$accessor' called on non-Result '$self'?"
                unless $self && blessed $self && $self->isa(__PACKAGE__);
    
            ($self->{$accessor}) = @_ if @_;
    
            return $self->{$accessor};
        };
        no strict 'refs';
        *{"$package\::$accessor"} = $code;
    }
}

_accessors(qw/caller pid depth in_todo source/);

sub init {}

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    my %params = @_;

    $params{pid} ||= $$;
    $params{caller} ||= [caller];

    for my $param (keys %params) {
        next unless $self->can($param);
        $self->$param($params{$param});
    }

    $self->init(%params);
    return $self;
}

sub type {
    my $self = shift;
    my $class = blessed($self);
    if ($class && $class =~ m/^.*::([^:]+)$/) {
        return lc($1);
    }

    confess "Could not determine result type for $self";
}

sub indent {
    my $self = shift;
    return '' unless $self->depth;
    return '    ' x $self->depth;
}

1;
