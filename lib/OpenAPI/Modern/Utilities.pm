use strictures 2;
package OpenAPI::Modern::Utilities;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Internal utilities and common definitions for OpenAPI::Modern

our $VERSION = '0.100';

use 5.020;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use namespace::clean;

use Exporter 'import';

our @EXPORT = qw(
  DEFAULT_SCHEMAS
  DEFAULT_DIALECT
  DEFAULT_BASE_METASCHEMA
  DEFAULT_METASCHEMA
  OAS_VOCABULARY
  OAD_VERSION
);

our @EXPORT_OK = qw();

# schema files to add by default
# these are also available as URIs with 'latest' instead of the timestamp.
use constant DEFAULT_SCHEMAS => [
  'oas/dialect/base.schema.json', # metaschema for json schemas contained within openapi documents
  'oas/meta/base.schema.json',    # vocabulary definition
  'oas/schema-base.json',         # the main openapi document schema + draft2020-12 jsonSchemaDialect
  'oas/schema.json',              # the main openapi document schema + permissive jsonSchemaDialect
  'strict-schema.json',
  'strict-dialect.json',
];

# these are all pre-loaded, and also made available as s/<date>/latest/
use constant DEFAULT_DIALECT => 'https://spec.openapis.org/oas/3.1/dialect/2024-11-10';
use constant DEFAULT_BASE_METASCHEMA => 'https://spec.openapis.org/oas/3.1/schema-base/2025-09-15';
use constant DEFAULT_METASCHEMA => 'https://spec.openapis.org/oas/3.1/schema/2025-09-15';
use constant OAS_VOCABULARY => 'https://spec.openapis.org/oas/3.1/meta/2024-11-10';

# it is likely the case that we can support a version beyond what's stated here -- but we may not,
# so we'll warn to that effect. Every effort will be made to upgrade this implementation to fully
# support the latest version as soon as possible.
use constant OAD_VERSION => '3.1.2';

1;
__END__

=pod

=head1 SYNOPSIS

  use OpenAPI::Modern::Utilities;

=head1 DESCRIPTION

This class contains common definitions and internal utilities to be used by L<OpenAPI::Modern>.

=for Pod::Coverage
DEFAULT_BASE_METASCHEMA
DEFAULT_DIALECT
DEFAULT_METASCHEMA
DEFAULT_SCHEMAS
OAD_VERSION
OAS_VOCABULARY

=cut
