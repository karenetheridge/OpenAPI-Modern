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
use File::ShareDir 'dist_dir';
use Path::Tiny;
use namespace::clean;

use Exporter 'import';

our @EXPORT = qw(
  DEFAULT_DIALECT
  DEFAULT_BASE_METASCHEMA
  DEFAULT_METASCHEMA
  STRICT_METASCHEMA
  STRICT_DIALECT
  OAS_VOCABULARY
  OAD_VERSION
);

our @EXPORT_OK = qw(
  BUNDLED_SCHEMAS
  OAS_SCHEMAS
  add_vocab_and_default_schemas
);

our %EXPORT_TAGS = (
  constants => \@EXPORT,
);

# see https://spec.openapis.org/#openapi-specification-schemas for the latest links
# these are updated automatically at build time via 'update-schemas'

# the main OpenAPI document schema, with permissive (unvalidated) JSON Schemas
use constant DEFAULT_METASCHEMA => 'https://spec.openapis.org/oas/3.1/schema/2025-09-15';

# metaschema for JSON Schemas contained within OpenAPI documents:
# standard JSON Schema (presently draft2020-12) + OpenAPI vocabulary
use constant DEFAULT_DIALECT => 'https://spec.openapis.org/oas/3.1/dialect/2024-11-10';

# OpenAPI document schema that forces the use of the JSON Schema dialect (no $schema overrides
# permitted)
use constant DEFAULT_BASE_METASCHEMA => 'https://spec.openapis.org/oas/3.1/schema-base/2025-09-15';

# OpenAPI vocabulary definition
use constant OAS_VOCABULARY => 'https://spec.openapis.org/oas/3.1/meta/2024-11-10';

# an OpenAPI schema and JSON Schema dialect which prohibit unknown keywords
use constant STRICT_METASCHEMA => 'https://raw.githubusercontent.com/karenetheridge/OpenAPI-Modern/master/share/strict-schema.json';
use constant STRICT_DIALECT => 'https://raw.githubusercontent.com/karenetheridge/OpenAPI-Modern/master/share/strict-dialect.json';

# identifier => local filename (under share/)
use constant BUNDLED_SCHEMAS => {
  DEFAULT_METASCHEMA, 'oas/schema.json',
  DEFAULT_DIALECT, 'oas/dialect/base.schema.json',
  DEFAULT_BASE_METASCHEMA, 'oas/schema-base.json',
  OAS_VOCABULARY, 'oas/meta/base.schema.json',
  STRICT_METASCHEMA, 'strict-schema.json',
  STRICT_DIALECT, 'strict-dialect.json',
};

# these are all pre-loaded, and also made available as s/<date>/latest/
use constant OAS_SCHEMAS => [
  grep m{/oas/3\.1/}, keys BUNDLED_SCHEMAS->%*,
];

# it is likely the case that we can support a version beyond what's stated here -- but we may not,
# so we'll warn to that effect. Every effort will be made to upgrade this implementation to fully
# support the latest version as soon as possible.
use constant OAD_VERSION => '3.1.2';

# simple runtime-wide cache of $ids to metaschema document objects that are sourced from disk
my $metaschema_cache = {};

sub add_vocab_and_default_schemas ($evaluator) {
  $evaluator->add_vocabulary('JSON::Schema::Modern::Vocabulary::OpenAPI');

  $evaluator->add_format_validation(int32 => +{
    type => 'number',
    sub => sub ($x) {
      require Math::BigInt; Math::BigInt->VERSION(1.999701);
      $x = Math::BigInt->new($x);
      return if $x->is_nan;
      my $bound = Math::BigInt->new(2) ** 31;
      $x >= -$bound && $x < $bound;
    }
  });

  $evaluator->add_format_validation(int64 => +{
    type => 'number',
    sub => sub ($x) {
      require Math::BigInt; Math::BigInt->VERSION(1.999701);
      $x = Math::BigInt->new($x);
      return if $x->is_nan;
      my $bound = Math::BigInt->new(2) ** 63;
      $x >= -$bound && $x < $bound;
    }
  });

  $evaluator->add_format_validation(float => +{ type => 'number', sub => sub ($x) { 1 } });
  $evaluator->add_format_validation(double => +{ type => 'number', sub => sub ($x) { 1 } });
  $evaluator->add_format_validation(password => +{ type => 'string', sub => sub ($) { 1 } });

  foreach my $uri (keys BUNDLED_SCHEMAS->%*) {
    my $document;
    if ($document = $metaschema_cache->{$uri}) {
      $evaluator->add_document($document);
    }
    else {
      my $file = path(dist_dir('OpenAPI-Modern'), BUNDLED_SCHEMAS->{$uri});
      my $schema = $evaluator->_json_decoder->decode($file->slurp_raw);
      $metaschema_cache->{$uri} = $document = $evaluator->add_schema($schema);
    }

    $evaluator->add_document($`.'/latest', $document)
      if $document->canonical_uri =~ m{/\d{4}-\d{2}-\d{2}$};
  }
}

1;
__END__

=pod

=head1 SYNOPSIS

  use OpenAPI::Modern::Utilities;

=head1 DESCRIPTION

This class contains common definitions and internal utilities to be used by L<OpenAPI::Modern>.

=for Pod::Coverage
BUNDLED_SCHEMAS
DEFAULT_BASE_METASCHEMA
DEFAULT_DIALECT
DEFAULT_METASCHEMA
OAD_VERSION
OAS_SCHEMAS
OAS_VOCABULARY
STRICT_DIALECT
STRICT_METASCHEMA
add_vocab_and_default_schemas

=cut
