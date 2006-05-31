use warnings;
use strict;

package Jifty::Web;

=head1 NAME

Jifty::Web - Web framework for a Jifty application

=cut



use Jifty::Everything;
use CGI::Cookie;
use XML::Writer;
use base qw/Class::Accessor::Fast Jifty::Object/;

use vars qw/$SERIAL/;

__PACKAGE__->mk_accessors(
    qw(next_page request response session temporary_current_user)
);

=head1 METHODS

=head3 new

Creates a new C<Jifty::Web> object

=cut

sub new {
    my $class = shift;
    my $self = bless {region_stack => []}, $class;
    $self->session(Jifty::Web::Session->new());
    return ($self);
}

=head3 mason

Returns a L<HTML::Mason::Request> object

=cut

sub mason {
    use HTML::Mason::Request;
    return HTML::Mason::Request->instance;
}


=head3 out

Send a string to the browser. The default implementation uses Mason->out;

=cut

sub out {
    shift->mason->out(@_);
}


=head3 url

Returns the root url of this Jifty application.  This is pulled from
the configuration file.  Takes an optional named parameter C<scheme>
to specify the scheme.

=cut

sub url {
    my $self = shift;
    my %args = @_;

    my $url  = Jifty->config->framework("Web")->{BaseURL};
    my $port = Jifty->config->framework("Web")->{Port};
    
    my $scheme = 'http';
    if ($url =~ /^(\w+)/) {
        $scheme = $1;
    }
    $scheme = $args{scheme} if $args{scheme};

    if ($ENV{'HTTP_HOST'}) {
        return $scheme ."://".$ENV{'HTTP_HOST'};
    }

    my $append_port = 0;
    if (   ( $scheme  eq 'http' and $port != 80 )
        or ( $scheme  eq'https' and $port != 443 ) ) {
        $append_port = 1;
    }
    return( $url . ($append_port ? ":$port" : ""));

}

=head3 serial 

Returns a unique identifier, guaranteed to be unique within the
runtime of a particular process (ie, within the lifetime of Jifty.pm).
There's no sort of global uniqueness guarantee, but it should be good
enough for generating things like moniker names.

=cut

sub serial {
    my $class = shift;

    # We don't use a lexical for the serial number, because then it
    # would be reset on module refresh
    $SERIAL ||= 0;
    return join( "S", ++$SERIAL, $$ );    # Start at 1.
}

=head2 SESSION MANAGEMENT

=head3 setup_session

Sets up the current C<session> object (a L<Jifty::Web::Session> tied
hash).  Aborts if the session is already loaded.

=cut

# Create the Jifty::Web::Session object
sub setup_session {
    my $self = shift;

    return if $self->session->loaded;
    $self->session->load();
}

=head3 session

Returns the current session's hash. In a regular user environment, it
persists, but a request can stop that by handing it a regular hash to
use.


=head2 CURRENT USER

=head3 current_user [USER]

Getter/setter for the current user; this gets or sets the 'user' key
in the session.  These are L<Jifty::Record> objects.

If a temporary_current_user has been set, will return that instead.

If the current application has no loaded current user, we get an empty
app-specific C<CurrentUser> object. (This
C<ApplicationClass>::CurrentUser class, a subclass of
L<Jifty::CurrentUser>, is autogenerated if it doesn't exist).

=cut

sub current_user {
    my $self = shift;
    if (@_) {
        my $user = shift;
         $self->session->set('user' => $user);
    }
    if (defined $self->temporary_current_user) {
        return $self->temporary_current_user;
    } elsif ($self->session->get('user')) {
        return $self->session->get('user');
    }
    else {
        my $object = (Jifty->config->framework('ApplicationClass')."::CurrentUser")->new();
        $object->is_superuser(1) if Jifty->config->framework('AdminMode');
        return ($object);
    }
}

=head3 temporary_current_user [USER]

Sets the current request's current_user to USER if set.

This value will _not_ be persisted to the session at the end of the
request.  To restore the original value, set temporary_current_user to
undef.

=cut

=head2 REQUEST

=head3 handle_request [REQUEST]

This method sets up a current session, and then processes the given
L<Jifty::Request> object.  If no request object is given, processes
the request object in L</request>.

Each action on the request is vetted in three ways -- first, it must
be marked as C<active> by the L<Jifty::Request> (this is the default).
Second, it must be in the set of allowed classes of actions (see
L<Jifty::API/is_allowed>).  Finally, the action must validate.  If it
passes all of these criteria, the action is fit to be run.

Before they are run, however, the request has a chance to be
interrupted and saved away into a continuation, to be resumed at some
later point.  This is handled by L</save_continuation>.

If the continuation isn't being saved, then C<handle_request> goes on
to run all of the actions.  If all of the actions are successful, it
looks to see if the request wished to call any continuations, possibly
jumping back and re-running a request that was interrupted in the
past.  This is handled by L</call_continuation>.

For more details about continuations, see L<Jifty::Continuation>.

=cut

sub handle_request {
    my $self = shift;
    die _( "No request to handle" ) unless Jifty->web->request;

    my @valid_actions;
    for my $request_action ( $self->request->actions ) {
        $self->log->debug("Found action ".$request_action->class . " " . $request_action->moniker);
        next unless $request_action->active;
        next if $request_action->has_run;
        unless ( Jifty->api->is_allowed( $request_action->class ) ) {
            $self->log->warn( "Attempt to call denied action '"
                    . $request_action->class
                    . "'" );
            next;
        }

        # Make sure we can instantiate the action
        my $action = $self->new_action_from_request($request_action);
        next unless $action;
        $request_action->modified(0);

        # Try validating -- note that this is just the first pass; as
        # actions are run, they may fill in values which alter
        # validation of later actions
        $self->log->debug("Validating action ".ref($action). " ".$action->moniker);
        $self->response->result( $action->moniker => $action->result );
        $action->validate;

        push @valid_actions, $request_action;
    }
    $self->save_continuation;

    unless ( $self->request->just_validating ) {
        for my $request_action (@valid_actions) {

            # Pull the action out of the request (again, since
            # mappings may have affected parameters).  This
            # returns the cached version unless the request has
            # been changed by argument mapping from previous
            # actions (Jifty::Request::Mapper)
            my $action = $self->new_action_from_request($request_action);
            next unless $action;
            if ($request_action->modified) {
                # If the request's action was changed, re-validate
                $action->result(Jifty::Result->new);
                $action->result->action_class(ref $action);
                $self->response->result( $action->moniker => $action->result );
                $self->log->debug("Re-validating action ".ref($action). " ".$action->moniker);
                next unless $action->validate;
            }

            $self->log->debug("Running action.");
            eval { $action->run; };
            $request_action->has_run(1);

            if ( my $err = $@ ) {
                # poor man's exception propagation
                # We need to get "LAST RULE" exceptions back up to the dispatcher
                die $err if ( $err =~ /^LAST RULE/ );
                $self->log->fatal($err);
                $action->result->error(
                    Jifty->config->framework("DevelMode")
                    ? $err
                    : "There was an error completing the request.  Please try again later."
                );
            }

            # Fill in the request with any results that that action
            # may have yielded.
            $self->request->do_mapping;
        }
    }
    $self->session->set_cookie();

    # If there's a continuation call, don't do the rest of this
    return if $self->response->success and $self->request->call_continuation;

    $self->redirect if $self->redirect_required;
    $self->request->do_mapping;
}

=head3 request [VALUE]

Gets or sets the current L<Jifty::Request> object.

=head3 response [VALUE]

Gets or sets the current L<Jifty::Response> object.

=head3 form

Returns the current L<Jifty::Web::Form> object, creating one if there
isn't one already.

=cut

sub form {
    my $self = shift;

    $self->{form} ||= Jifty::Web::Form->new;
    return $self->{form};
}

=head3 new_action class => CLASS, moniker => MONIKER, order => ORDER, arguments => PARAMHASH

Creates a new action (an instance of a subclass of L<Jifty::Action>)

C<CLASS> is L<qualified|Jifty::Util/qualify>, and an instance of that
class is created, passing the C<Jifty::Web> object, the C<MONIKER>,
and any other arguments that C<new_action> was supplied.

C<MONIKER> is a unique designator of an action on a page.  The moniker
is content-free and non-fattening, and may be auto-generated.  It is
used to tie together arguments that relate to the same action.

C<ORDER> defines the order in which the action is run, with lower
numerical values running first.

C<ARGUMENTS> are passed to the L<Jifty::Action/new> method.  In
addition, if the current request (C<$self->request>) contains an
action with a matching moniker, any arguments that are in that
requested action but not in the C<PARAMHASH> list are set.  This
implements "sticky fields".

=cut

sub new_action {
    my $self = shift;

    my %args = (
        class     => undef,
        moniker   => undef,
        arguments => {},
        @_
    );

    my %arguments = %{ $args{arguments} };

    if ( $args{'moniker'} ) {
        my $action_in_request = $self->request->action( $args{moniker} );

    # Fields explicitly passed to new_action take precedence over those passed
    # from the request; we read from the request to implement "sticky fields".
    #
        if ( $action_in_request and $action_in_request->arguments ) {
            %arguments = ( %{ $action_in_request->arguments }, %arguments );
        }
    }

    # "Untaint" -- the implementation class is provided by the client!)
    # Allows anything that a normal package name allows
    my $class = delete $args{class};
    unless ( $class =~ /^([0-9a-zA-Z_:]+)$/ ) {
        $self->log->error( "Bad action implementation class name: ", $class );
        return;
    }
    $class = $1;    # 'untaint'

    # Prepend the base path (probably "App::Action") unless it's there already
    $class = Jifty->api->qualify($class);

    # The implementation class is provided by the client, so this
    # isn't a "shouldn't happen"
    return unless Jifty::Util->require( $class );

    my $action;
    # XXX TODO bullet proof
    eval { $action = $class->new( %args, arguments => {%arguments} ); };
    if ($@) {
        my $err = $@;
        $self->log->fatal($err);
        return;
    }

    $self->{'actions'}{ $action->moniker } = $action;

    return $action;
}

=head3 new_action_from_request REQUESTACTION

Given a L<Jifty::Request::Action>, creates a new action using C<new_action>.

=cut

sub new_action_from_request {
    my $self       = shift;
    my $req_action = shift;
    return $self->{'actions'}{ $req_action->moniker } if 
      $self->{'actions'}{ $req_action->moniker } and not $req_action->modified;
    $self->new_action(
        class     => $req_action->class,
        moniker   => $req_action->moniker,
        order     => $req_action->order,
        arguments => $req_action->arguments || {}
    );
}

=head3 failed_actions

Returns an array of L<Jifty::Action> objects, one for each
L<Jifty::Request::Action> that is marked as failed in the current
response.

=cut

sub failed_actions {
    my $self = shift;
    my @actions;
    for my $req_action ($self->request->actions) {
        next unless $self->response->result($req_action->moniker);
        next unless $self->response->result($req_action->moniker)->failure;
        push @actions, $self->new_action_from_request($req_action);
    }
    return @actions;
}

=head3 succeeded_actions

As L</failed_actions>, but for actions that completed successfully;
less often used.

=cut

sub succeeded_actions {
    my $self = shift;
    my @actions;
    for my $req_action ($self->request->actions) {
        next unless $self->response->result($req_action->moniker);
        next unless $self->response->result($req_action->moniker)->success;
        push @actions, $self->new_action_from_request($req_action);
    }
    return @actions;
}

=head2 REDIRECTS AND CONTINUATIONS

=head3 next_page [VALUE]

Gets or sets the next page for the framework to show.  This is
normally set during the C<take_action> method or a L<Jifty::Action>

=head3 redirect_required

Returns true if we need to redirect, now that we've processed all the
actions.  The current logic just looks to see if a different
L</next_page> has been set. We probably want to make it possible to
force a redirect, even if we're redirecting back to the current page

=cut

sub redirect_required {
    my $self = shift;

    if ($self->next_page
        and ( ( $self->next_page ne $self->request->path )
            or $self->request->state_variables
            or $self->{'state_variables'} )
        )
    {
        return (1);

    } else {
        return undef;
    }
}

=head3 redirect [URL]

Redirect to the next page. If you pass this method a parameter, it
redirects to that URL rather than B<next_page>.

It creates a continuation of where you want to be, and then calls it.

=cut

sub redirect {
    my $self = shift;
    my $page = shift || $self->next_page;

    my @actions = Jifty->web->request->actions;

    if (   $self->response->results
        or $self->request->state_variables
        or $self->{'state_variables'}
        or $self->request->continuation
        or @actions )
    {
        my $request = Jifty::Request->new();
        $request->path($page);
        $request->add_state_variable( key => $_->key, value => $_->value )
          for $self->request->state_variables;
        $request->add_state_variable( key => $_, value => $self->{'state_variables'}->{$_} )
          for keys %{ $self->{'state_variables'} };
        for (@actions) {
            $request->add_action(
                moniker   => $_->moniker,
                class     => $_->class,
                order     => $_->order,
                active    => $_->active && (not $_->has_run),
                has_run   => $_->has_run,
                arguments => $_->arguments,
            );
        }
        $request->continuation($self->request->continuation);
        my $cont = Jifty::Continuation->new(
            request  => $request,
            response => $self->response,
            parent   => $self->request->continuation,
        );
        if ($page =~ /\?/) {
            $page .= "&";
        } else {
            $page .= "?";
        }
        $page .="J:CALL=" . $cont->id;
    }
    $self->_redirect($page);
}

sub _redirect {
    my $self = shift;
    my ($page) = @_;

    # $page can't lead with // or it assumes it's a URI scheme.
    $page =~ s{^/+}{/};

    # This is designed to work under CGI or FastCGI; will need an
    # abstraction for mod_perl

    # Clear out the mason output, if any
    $self->mason->clear_buffer if $self->mason;

    my $apache = Jifty->handler->apache;

    $self->log->debug("Redirecting to $page");
    # Headers..
    $apache->header_out( Location => $page );
    $apache->header_out( Status => 302 );
    $apache->send_http_header();

    # Abort or last_rule out of here
    $self->mason->abort if $self->mason;
    Jifty::Dispatcher::last_rule();

}

=head3 save_continuation

Saves the current request and response if we've been asked to.  If we
save the continuation, we redirect to the next page -- the call to
C<save_continuation> never returns.

=cut

sub save_continuation {
    my $self = shift;

    my %args = %{ $self->request->arguments };
    my $clone = delete $self->request->arguments->{'J:CLONE'};
    my $create = delete $self->request->arguments->{'J:CREATE'};
    if ( $clone or $create ) {

        # Saving a continuation
        my $c = Jifty::Continuation->new(
            request  => $self->request,
            response => $self->response,
            parent   => $self->request->continuation,
            clone    => $clone,
        );

# XXX Only if we're cloning should we do the following check, I think??  Cloning isn't a stack push, so it works out
        if ( $clone
            and $self->request->just_validating
            and $self->response->failure )
        {

# We don't get to redirect to the new page; redirect to the same page, new cont
            $self->_redirect(
                $self->request->path . "?J:C=" . $c->id );
        } else {

            # Set us up with the new continuation
            $self->_redirect( Jifty::Web->url . $args{'J:PATH'}
                    . ( $args{'J:PATH'} =~ /\?/ ? "&" : "?" ) . "J:C="
                    . $c->id );
        }

    }
}

=head3 multipage START_URL, ARGUMENTS

B<Note>: This API is very much not finalized.  Don't use it yet!

Create a multipage action.  The first argument is the URL of the start
of the multipage action -- the user will be redirected there if they
try to enter the multipage action on any other page.  The rest of the
arguments are passed to L<Jifty::Request/add_action> to create the
multipage action.

=cut

sub multipage {
    my $self = shift;
    my ( $start, %args ) = @_;

    my $request_action = Jifty->web->caller->action( $args{moniker} );

    unless ($request_action) {
        my $request = Jifty::Request->new();
        $request->argument(
            'J:CALL' => Jifty->web->request->continuation->id )
            if Jifty->web->request->continuation;
        $request->path("/");
        $request->add_action(%args);
        my $cont = Jifty::Continuation->new( request => $request );
        Jifty->web->redirect( $start . "?J:C=" . $cont->id );
    }

    my $action = Jifty->web->new_action_from_request($request_action);
    $action->result(
        Jifty->web->request->continuation->response->result( $args{moniker} )
        )
        if Jifty->web->request->continuation->response;
    return $action;
}

=head3 caller

Returns the L<Jifty::Request> of our enclosing continuation, or an
empty L<Jifty::Request> if we are not in a continuation.

=cut

sub caller {
    my $self = shift;

    return Jifty::Request->new unless $self->request->continuation;
    return $self->request->continuation->request;
}

=head2 HTML GENERATION

=head3 tangent PARAMHASH

If called in non-void context, creates and renders a
L<Jifty::Web::Form::Clickable> with the given I<PARAMHASH>, forcing a
continuation save.

In void context, does a redirect to the URL that the
L<Jifty::Web::Form::Clickable> object generates.

Both of these versions preserve all state variables by default.

=cut

sub tangent {
    my $self = shift;

    my $clickable = Jifty::Web::Form::Clickable->new(
        returns        => { },
        preserve_state => 1,
        @_
    );
    if ( defined wantarray ) {
        return $clickable->generate;
    } else {
        $clickable->state_variable( $_ => $self->{'state_variables'}{$_} )
            for keys %{ $self->{'state_variables'} };

        my $request = Jifty::Request->new(path => Jifty->web->request->path)
          ->from_webform(%{Jifty->web->request->arguments}, $clickable->get_parameters);
        local Jifty->web->{request} = $request;
        Jifty->web->handle_request();
    }
}

=head3 goto PARAMHASH

Does an instant redirect to the url generated by the
L<Jifty::Web::Form::Clickable> object generated by the I<PARAMHASH>.

=cut

sub goto {
    my $self = shift;
    Jifty->web->redirect(
        Jifty::Web::Form::Clickable->new(@_)->complete_url );
}

=head3 link PARAMHASH

Generates and renders a L<Jifty::Web::Form::Clickable> using the given
I<PARAMHASH>.

=cut

sub link {
    my $self = shift;
    return Jifty::Web::Form::Clickable->new(@_)->generate;
}

=head3 return PARAMHASH

Generates and renders a L<Jifty::Web::Form::Clickable> using the given
I<PARAMHASH>, additionally defaults to calling the current
continuation.

Takes an additional argument, C<to>, which can specify a default path
to return to if there is no current continuation.

=cut

sub return {
    my $self = shift;
    my %args = (@_);
    my $continuation = Jifty->web->request->continuation;
    if (not $continuation and $args{to}) {
        $continuation = Jifty::Continuation->new(request => Jifty::Request->new(path => $args{to}));
    }
    delete $args{to};

    $self->link( call => $continuation, %args );
}

=head3 render_messages [MONIKER]

Outputs any messages that have been added, in a <div id="messages">
tag.  Messages are added by calling L<Jifty::Result/message>.

If a moniker is specified, only messages for that moniker 
are rendered.


=cut

# XXX TODO factor out error and message rendering as separate

sub render_messages {
    my $self = shift;
    my $only_moniker = '';
    $only_moniker = shift if (@_);
    my %results = $self->response->results;

    return '' unless %results;

    my @monikers = ($only_moniker) || sort keys %results;

    for my $type (qw(error message)) {
        next unless grep { defined $results{$_}  and $results{$_}->$type() } @monikers;

        my $plural = $type . "s";
        $self->out(qq{<div id="$plural">});
        foreach my $moniker ( @monikers ) {
            if ( $results{$moniker}->$type() ) {
                $self->out( qq{<div class="$type $moniker">}
                    . $results{$moniker}->$type()
                    . qq{</div>} );
            }
        }
        $self->out(qq{</div>});
    }
    return '';
}

=head3 query_string KEY => VALUE [, KEY => VALUE [, ...]]

Returns an URL-encoded query string piece representing the arguments
passed to it.

=cut

sub query_string {
    my $self = shift;
    my %args = @_;
    my @params;
    while ( ( my $key, my $value ) = each %args ) {
        push @params,
            $key . "=" . $self->escape_uri( $value );
    }
    return ( join( ';', @params ) );
}

=head3 escape STRING

HTML-escapes the given string and returns it

=cut

sub escape {
    my $self = shift;
    return join '', map {my $html = $_; Jifty::View::Mason::Handler::escape_utf8( \$html ); $html} @_;
}

=head3 escape_uri STRING

URI-escapes the given string and returns it

=cut

sub escape_uri {
    my $self = shift;
    return join '', map {my $uri = $_; Jifty::View::Mason::Handler::escape_uri( \$uri ); $uri} @_;
}

=head3 navigation

Returns the L<Jifty::Web::Menu> for this web request; one is
automatically created if it hasn't been already.

=cut

sub navigation {
    my $self = shift;
    if (!$self->{navigation}) {
        $self->{navigation} = Jifty::Web::Menu->new();
    }
    return $self->{navigation};
}

=head3 page_navigation

Returns the L<Jifty::Web::Menu> for this web request; one is
automatically created if it hasn't been already.  This is useful
for separating page-level navigation from app-level navigation.

=cut

sub page_navigation {
    my $self = shift;
    if (!$self->{page_navigation}) {
        $self->{page_navigation} = Jifty::Web::Menu->new();
    }
    return $self->{page_navigation};
}

=head2 STATE VARIABLES

=head3 get_variable NAME

Gets a page specific variable from the request object.

=cut

sub get_variable {
    my $self = shift;
    my $name = shift;
    my $var  = $self->request->state_variable($name);
    return undef unless ($var);
    return $var->value();

}

=head3 set_variable NAME VALUE

Takes a key-value pair for variables to serialize and hand off to the next page.

Behind the scenes, these variables get serialized into every link or
form that is marked as 'state preserving'.  See
L<Jifty::Web::Form::Clickable>.

=cut

sub set_variable {
    my $self  = shift;
    my $name  = shift;
    my $value = shift;

    $self->{'state_variables'}->{$name} = $value;

}

=head3 state_variables

Returns all of the state variables that have been set for the next
request, as a hash; they have already been prefixed with C<J:V->

=cut

# FIXME: it seems wrong to have an accessor that exposes the
# representation, so to speak
sub state_variables {
    my $self = shift;
    my %vars;
    $vars{ "J:V-" . $_ } = $self->{'state_variables'}->{$_}
        for keys %{ $self->{'state_variables'} };

    return %vars;
}

=head2 REGIONS

=head3 get_region [QUALIFIED NAME]

Given a fully C<QUALIFIED NAME> of a region, returns the
L<Jifty::Web::PageRegion> with that name, or undef if no such region
exists.

=cut

sub get_region {
    my $self = shift;
    my ($name) = @_;
    return $self->{'regions'}{$name};
}

=head3 region PARAMHASH

The provided PARAMHASH is used to create and render a
L<Jifty::Web::PageRegion>; the C<PARAMHASH> is passed directly to its
L<Jifty::Web::PageRegion/new> method, and then
L<Jifty::Web::PageRegion/render> is called.

=cut

sub region {
    my $self = shift;

    # Create a region
    my $region = Jifty::Web::PageRegion->new(@_) or return; 

    # Render it
    $region->render;
}

=head3 current_region

Returns the name of the current L<Jifty::Web::PageRegion>, or undef if
there is none.

=cut

sub current_region {
    my $self = shift;
    return $self->{'region_stack'}
        ? $self->{'region_stack'}[-1]
        : undef;
}

=head3 qualified_region [REGION]

Returns the fully qualified name of the current
L<Jifty::Web::PageRegion>, or the empty string if there is none.  If
C<REGION> is supplied, gives the qualified name of C<REGION> were it
placed in the current region.

=cut

sub qualified_region {
    my $self = shift;
    return join( "-", map { $_->name } @{ $self->{'region_stack'} || [] }, @_ );
}

1;
