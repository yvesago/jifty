package Jifty::View::Declare::Page;
use strict;
use warnings;
use base qw/Template::Declare/;
use Template::Declare::Tags;

use base 'Class::Accessor::Fast';

=head1 NAME

Jifty::View::Declare::Page

=head1 DESCRIPTION

This library provides page wrappers

=head1 METHODS

=cut

use Jifty::View::Declare::Helpers;

__PACKAGE__->mk_accessors(qw(content_code done_header _title));

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);

    my ($title) = get_current_attr(qw(title));
    $self->_title($title);

    return $self;
}

sub render_header {
    my $self = shift;
    return if $self->done_header;

    Template::Declare->new_buffer_frame;
    outs_raw(
        '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">'
      . '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">' );
    Jifty::View::Declare::Helpers::render_header($self->_title || Jifty->config->framework('ApplicationName'));

    $self->done_header(Template::Declare->buffer->data);
    Template::Declare->end_buffer_frame;
    return '';
};

sub render_body {
    my ($self, $body_code) = @_;

    body { $body_code->() };
}

sub render_page {
    my $self = shift;

    div {
        div {
            show 'salutation';
            show 'menu';
        };
        div {
            attr { id is 'content' };
            div {
                {
                    no warnings qw( uninitialized redefine once );

                    local *is::title = $self->mk_title_handler();
                    $self->render_pre_content_hook();
                    Jifty->web->render_messages;

                    $self->content_code->();
                    $self->render_header();

                    $self->render_jifty_page_detritus();
                }

            };
        };
    };
}

sub mk_title_handler {
    my $self = shift; shift;
    for (@_) {
        if ( ref($_) eq 'CODE' ) {
            Template::Declare->new_buffer_frame;
            $_->();
            $self->_title( $self->_title . Template::Declare->buffer->data );
            Template::Declare->end_buffer_frame;
        } else {
            $self->_title( $self->_title . Jifty->web->escape($_) );
        }
    }
    $self->render_header;
    my $oldt = get('title');
    set( title => $self->_title );
    show 'heading_in_wrapper';
    set( title => $oldt );
}

sub render_footer {
    my $self = shift;
    outs_raw('</html>');
    Template::Declare->buffer->data( $self->done_header . Template::Declare->buffer->data );
}


sub render_pre_content_hook {
    if ( Jifty->config->framework('AdminMode') ) {
        with( class => "warning admin_mode" ), div {
            outs( _('Alert') . ': ' );
            outs_raw(
                Jifty->web->tangent(
                    label => _('Administration mode is enabled.'),
                    url   => '/__jifty/admin/'
                )
            );
            }
    }
}

sub render_jifty_page_detritus {

    show('keybindings');
    with( id => "jifty-wait-message", style => "display: none" ),
        div { _('Loading...') };

    # This is required for jifty server push.  If you maintain your own
    # wrapper, make sure you have this as well.
    if ( Jifty->config->framework('PubSub')->{'Enable'} && Jifty::Subs->list )
    {
        script { outs('new Jifty.Subs({}).start();') };
    }
}


1;
