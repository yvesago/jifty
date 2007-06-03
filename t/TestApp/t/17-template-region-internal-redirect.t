#!/usr/bin/env perl
use warnings;
use strict;

use lib 't/lib';
use Jifty::SubTest;

use Jifty::Test;
use Jifty::Test::WWW::Mechanize;

plan tests => 7;


my $server = Jifty::Test->make_server;
isa_ok( $server, 'Jifty::Server' );
my $URL = $server->started_ok;


my $mech = Jifty::Test::WWW::Mechanize->new;

$mech->get_ok( $URL."/region-with-internal-redirect");
$mech->content_like(qr'redirected ok');
$mech->content_like(qr'other region');
$mech->content_like(qr'still going');
$mech->content_unlike(qr'sorry');


1;
