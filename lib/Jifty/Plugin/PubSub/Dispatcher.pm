use warnings;
use strict;

package Jifty::Plugin::PubSub::Dispatcher;

=head1 NAME

Jifty::Plugin::PubSub::Dispatcher - Dispatcher for PubSub plugin

=head1 DESCRIPTION

=cut

use Jifty::Dispatcher -base;

on '/=/subs' => stream {
    my $req = Jifty->web->request;
    my $forever = $req->parameters->{'forever'} || 0;
    my $web = Jifty->web;
    return sub {
        local $Jifty::WEB = $web;

        my $respond = shift;
        my $w = $respond->([200,
                            ['Content-Type' => 'text/html; charset=utf-8',
                             'Pragma' => 'no-cache',
                             'Cache-control' => 'no-cache' ] ]);

        use IO::Handle::Util qw(io_prototype);

        my $writer = XML::Writer->new( OUTPUT => io_prototype
                                           print => sub { shift;
                                                          $w->write(shift);
                                                      } );
        $writer->xmlDecl( "UTF-8", "yes" );

        my $begin = <<'END';
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
 "http://www.w3.org/TR/2002/REC-xhtml1-20020801/DTD/xhtml1-strict.dtd">
<html><head><title></title></head>
END

        chomp $begin;

        if ($forever) {
            my $whitespace = " " x ( 1024 - length $begin );
            $begin =~ s/<body>$/$whitespace<body>/s;
        }

        $w->write($begin);
        $writer->startTag("body");

        local $SIG{PIPE} = sub {
            die "ABORT";
        };

        my $loops;
        while (Jifty->config->framework('PubSub')->{'Enable'}) {
            Jifty->web->out(" ") if ++$loops % 10 == 0;
            my $sent = write_subs_once($writer);
            last if ( $sent && !$forever );
            sleep 1;
        }
        $writer->endTag();
    };
};

sub write_subs_once {
    my $writer = shift;
    Jifty::Subs::Render->render(
        Jifty->web->session->id,
        sub {
            my ( $mode, $name, $content, $attrs ) = @_;
            $writer->startTag( "pushfrag", mode => $mode, %{$attrs || {}} );
            $writer->startTag( "fragment", id   => $name );
            $writer->dataElement( "content", $content );
            $writer->endTag();
            $writer->endTag();
        }
    );
}

1;
