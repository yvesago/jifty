#!/usr/bin/env perl
use warnings;
use strict;

use Jifty::Test::Dist tests => 20;
use Jifty::Test::WWW::Mechanize;

my $server  = Jifty::Test->make_server;
isa_ok($server, 'Jifty::Server');

my $URL     = $server->started_ok;
my $mech    = Jifty::Test::WWW::Mechanize->new();

ok(1, 'Loaded the test script');

my $u1 = TestApp::Plugin::REST::Model::User->new(
    current_user => TestApp::Plugin::REST::CurrentUser->superuser,
);
$u1->create(name => 'test', email => 'test@example.com');
ok($u1->id);

my %loader = (
    yml  => \&Jifty::YAML::Load,
    json => \&Jifty::JSON::jsonToObj,
);
sub fetch {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    my ($url, $format) = @_;

    if (!exists($loader{$format})) {
        die "Invalid format '$format'. Valid formats are: "
          . join ', ', sort keys %loader;
    }

    $mech->get_ok("$URL$url.$format", "Get $url in $format");
    is($mech->status, 200, "HTTP response status for $URL$url.$format");
    my $from_dot_format = $loader{$format}->($mech->content);

    return $from_dot_format;
}

my $list = fetch('/=/model', 'yml');
is(scalar @$list, 2, 'Got two models in YAML');
is($list->[0],'TestApp.Plugin.REST.Model.Group');
is($list->[1],'TestApp.Plugin.REST.Model.User');

$list = fetch('/=/model', 'json');
is(scalar @$list, 2, 'Got two models in JSON');
is($list->[0],'TestApp.Plugin.REST.Model.Group');
is($list->[1],'TestApp.Plugin.REST.Model.User');

my $user = fetch('/=/model/User', 'yml');
is(scalar keys %$user, 4, 'four keys in the user record, YAML');

$user = fetch('/=/model/User', 'json');
is(scalar keys %$user, 4, 'four keys in the user record, JSON');

__END__

$mech->get_ok('/=/model/user');
is($mech->status,'200');
$mech->get_ok('/=/model/TestApp::Plugin::REST::Model::User');
is($mech->status,'200');
$mech->get_ok('/=/model/TestApp.Plugin.REST.Model.User');
is($mech->status,'200');
$mech->get_ok('/=/model/testapp.plugin.rest.model.user');
is($mech->status,'200');


$mech->get_ok('/=/model/User.yml');
my %keys =  %{get_content()};

is((0+keys(%keys)), 4, "The model has 4 keys");
is_deeply([sort keys %keys], [sort qw/id name email tasty/]);


# on GET    '/=/model/*/*'   => \&list_model_items;
$mech->get_ok('/=/model/user/id.yml');
my @rows = @{get_content()};
is($#rows,0);


# on GET    '/=/model/*/*/*' => \&show_item;
$mech->get_ok('/=/model/user/id/1.yml');
my %content = %{get_content()};
is_deeply(\%content, { name => 'test', email => 'test@example.com', id => 1, tasty => undef });

# on GET    '/=/model/*/*/*/*' => \&show_item_Field;
$mech->get_ok('/=/model/user/id/1/email.yml');
is(get_content(), 'test@example.com');

# on PUT    '/=/model/*/*/*' => \&replace_item;
# on DELETE '/=/model/*/*/*' => \&delete_item;

# on POST   '/=/model/*'     => \&create_item;
$mech->post( $URL . '/=/model/User', { name => "moose", email => 'moose@example.com' } );
is($mech->status, 200, "create via POST to model worked");

$mech->post( $URL . '/=/model/Group', { } );
is($mech->status, 403, "create via POST to model with disallowed create action failed with 403");

# on GET    '/=/search/*/**' => \&search_items;
$mech->get_ok('/=/search/user/id/1.yml');
my $content = get_content();
is_deeply($content, [{ name => 'test', email => 'test@example.com', id => 1, tasty => undef }]);

$mech->get_ok('/=/search/user/id/1/name/test.yml');
$content = get_content();
is_deeply($content, [{ name => 'test', email => 'test@example.com', id => 1, tasty => undef }]);

$mech->get_ok('/=/search/user/id/1/name/test/email.yml');
$content = get_content();
is_deeply($content, ['test@example.com']);

$mech->get('/=/search/Usery/id/1.yml');
is($mech->status,'404');

$mech->get('/=/search/user/id/1/name/foo.yml');
is($mech->status,'200');
$content = get_content();
is_deeply($content, []);

# on GET    '/=/action'      => \&list_actions;

my @actions = qw(
                 TestApp.Plugin.REST.Action.UpdateGroup
                 TestApp.Plugin.REST.Action.DeleteGroup
                 TestApp.Plugin.REST.Action.SearchGroup
                 TestApp.Plugin.REST.Action.ExecuteGroup
                 TestApp.Plugin.REST.Action.CreateUser
                 TestApp.Plugin.REST.Action.UpdateUser
                 TestApp.Plugin.REST.Action.DeleteUser
                 TestApp.Plugin.REST.Action.SearchUser
                 TestApp.Plugin.REST.Action.ExecuteUser
                 TestApp.Plugin.REST.Action.DoSomething
                 Jifty.Action.Autocomplete
                 Jifty.Action.Redirect);

$mech->get_ok('/=/action/');
is($mech->status, 200);
for (@actions) {
    $mech->content_contains($_);
}
$mech->get_ok('/=/action.yml');
my @got = @{get_content()};

is(
    join(",", sort @got ),
    join(",",sort @actions), 
, "Got all the actions as YAML");


# on GET    '/=/action/*'    => \&list_action_params;

$mech->get_ok('/=/action/DoSomething');
is($mech->status, 200);
$mech->get_ok('/=/action/TestApp::Plugin::REST::Action::DoSomething');
is($mech->status, 200);
$mech->get_ok('/=/action/TestApp.Plugin.REST.Action.DoSomething');
is($mech->status, 200);

# Parameter name
$mech->content_contains('email');
# Parameter label
$mech->content_contains('Email');
# Default value
$mech->content_contains('example@email.com');

$mech->get_ok('/=/action/DoSomething.yml');
is($mech->status, 200);

my %args = %{get_content()};
ok($args{email}, "Action has an email parameter");
is($args{email}{label}, 'Email', 'email has the correct label');
is($args{email}{default_value}, 'example@email.com', 'email has the correct default');


# on POST   '/=/action/*'    => \&run_action;
# 

$mech->post( $URL . '/=/action/DoSomething', { email => 'good@email.com' } );

$mech->content_contains('Something happened!');

$mech->post( $URL . '/=/action/DoSomething', { email => 'bad@email.com' } );

$mech->content_contains('Bad looking email');
$mech->content_lacks('Something happened!');

$mech->post( $URL . '/=/action/DoSomething', { email => 'warn@email.com' } );
    
$mech->content_contains('Warning for email');
$mech->content_contains('Something happened!');

# Test YAML posts
$mech->post ( $URL . '/=/action/DoSomething.yml', { email => 'good@email.com' } );

eval {
    %content = %{get_content()};
};

ok($content{success});
is($content{message}, 'Something happened!');

    
$mech->post ( $URL . '/=/action/DoSomething.yaml', { email => 'bad@email.com' } );

eval {
    %content = %{get_content()};
};

ok(!$content{success}, "Action that doesn't validate fails");
is($content{field_errors}{email}, 'Bad looking email');


sub get_content { return Jifty::YAML::Load($mech->content)}

1;
