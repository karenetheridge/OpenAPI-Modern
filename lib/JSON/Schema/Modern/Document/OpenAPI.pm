use strict;
use warnings;
package JSON::Schema::Modern::Document::OpenAPI;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: One JSON Schema document
# KEYWORDS: JSON Schema data validation request response OpenAPI

our $VERSION = '0.001';

use 5.016;
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use JSON::Schema::Modern::Utilities 0.524 qw(assert_keyword_exists assert_keyword_type E);
use Moo;
use namespace::clean;

extends 'JSON::Schema::Modern::Document';

sub traverse {
  my ($self, $evaluator) = @_;

  my $schema = $self->schema;

  my $state = {
    initial_schema_uri => $self->canonical_uri,
    traversed_schema_path => '',
    schema_path => '',
    data_path => '',
    errors => [],
    evaluator => $evaluator,
    identifiers => [],
    configs => {},
    spec_version => $evaluator->SPECIFICATION_VERSION_DEFAULT,
    vocabularies => [],
  };

  # /openapi
  return $state if not assert_keyword_exists({ %$state, keyword => 'openapi' }, $schema)
    or not assert_keyword_type({ %$state, keyword => 'openapi' }, $schema, 'string');

  my $valid = 1;
  $valid = E({ %$state, keyword => 'openapi' }, 'unrecognized openapi version %s', $schema->{openapi})
    if $schema->{openapi} !~ /^3\.1\.[0-9]+(-.+)?$/;

  # /info -> /info/title, /info/version
  {
    my $state = { %$state, schema_path => $state->{schema_path}.'/info', keyword => 'info' };

    return $state if not assert_keyword_exists($state, $schema)
      or not assert_keyword_type($state, $schema, 'object')
      or not grep
        assert_keyword_exists($state, $schema)
          && assert_keyword_type({ %$state, keyword => $_, schema_path => '/info' }, $schema->{info}, 'string'),
        qw(title version);
  }

  # TODO: determine default json_schema_dialect from /jsonSchemaDialect

  return $state;
}

1;
__END__

=pod

=head1 SYNOPSIS

  use JSON::Schema::Modern;
  use JSON::Schema::Modern::Document::OpenAPI;

  my $js = JSON::Schema::Modern->new;
  my $openapi_document = JSON::Schema::Modern::Document::OpenAPI->new(
    evaluator => $js,
    canonical_uri => 'https://example.com/v1/api',
    schema => $schema,
    metaschema_uri => 'https://example.com/my_custom_dialect',
  );

=head1 DESCRIPTION

Provides structured parsing of an OpenAPI document, suitable as the base for more tooling such as
request and response validation, code generation or form generation.

The provided document must be a valid OpenAPI document, as specified by the schema identified by
C<https://spec.openapis.org/oas/3.1/schema-base/2021-09-28> (the latest document available)
and the L<OpenAPI v3.1 specification|https://spec.openapis.org/oas/v3.1.0>.

=cut
