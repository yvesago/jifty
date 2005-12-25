use warnings;
use strict;
 
package JFDI::Web::Form::Field::Password;

use base qw/JFDI::Web::Form::Field/;

=head2 type

The HTML input type is C<password>.

=cut

sub type { 'password' }

=head2 default_value

The default value of a password field should B<always> be empty.

=cut

sub default_value {''}

1;
