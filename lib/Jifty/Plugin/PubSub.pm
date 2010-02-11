use strict;
use warnings;

package Jifty::Plugin::PubSub;
use base 'Jifty::Plugin';
use Plack::Builder;
use Plack::Util;

=head1 NAME

Jifty::Plugin::Deflater - Handles Accept-Encoding and compression

=head1 SYNOPSIS

# In your jifty config.yml under the framework section:

  Plugins:
    - PubSub: {}

# You should put defalter at the end of the plugins list

=head1 DESCRIPTION

This plugin provides Accept-Encoding handling.

=cut

sub init {
    my $self = shift;
    return if $self->_pre_init;

    Jifty->web->add_javascript( 'jifty_subs.js' );
}

1;
