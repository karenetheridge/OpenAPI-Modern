use strict;
use warnings;
package OpenAPI::Modern;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: ...
# KEYWORDS: ...

our $VERSION = '0.001';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';

1;
__END__

=pod

=head1 SYNOPSIS

  use OpenAPI::Modern;

  ...

=head1 DESCRIPTION

...

=head1 FUNCTIONS/METHODS

=head2 foo

...

=head1 ACKNOWLEDGEMENTS

...

=head1 SEE ALSO

=for :list
* L<foo>

=cut
