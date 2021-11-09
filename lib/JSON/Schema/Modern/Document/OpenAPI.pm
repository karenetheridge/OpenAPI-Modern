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
use Safe::Isa;
use File::ShareDir 'dist_dir';
use Path::Tiny;
use Moo;
use Types::Standard 'InstanceOf';
use namespace::clean;

extends 'JSON::Schema::Modern::Document';

use constant DEFAULT_DIALECT => 'https://spec.openapis.org/oas/3.1/dialect/base';

use constant DEFAULT_SCHEMAS => {
  'oas/dialect/base.schema.json' => 'https://spec.openapis.org/oas/3.1/dialect/base',
  'oas/meta/base.schema.json'    => 'https://spec.openapis.org/oas/3.1/meta/base',
};

has '+evaluator' => (
  required => 1,
);

has json_schema_dialect => (
  is => 'rwp',
  isa => InstanceOf['Mojo::URL'],
  coerce => sub { $_[0]->$_isa('Mojo::URL') ? $_[0] : Mojo::URL->new($_[0]) },
);

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

  # /jsonSchemaDialect

  return $state if exists $schema->{jsonSchemaDialect}
    and not assert_keyword_type({ %$state, keyword => 'jsonSchemaDialect' }, $schema, 'string');

  my $json_schema_dialect = $self->json_schema_dialect // $schema->{jsonSchemaDialect};

  if (not $json_schema_dialect) {
    # "If [jsonSchemaDialect] is not set, then the OAS dialect schema id MUST be used for these Schema Objects."
    $evaluator->add_vocabulary('JSON::Schema::Modern::Vocabulary::OpenAPI');

    foreach my $filename (keys %{(DEFAULT_SCHEMAS)}) {
      $evaluator->add_schema(
        DEFAULT_SCHEMAS->{$filename},
        $evaluator->_json_decoder->decode(path(dist_dir('JSON-Schema-Modern-Document-OpenAPI'), $filename)->slurp_raw),
      );
    }
    $json_schema_dialect = DEFAULT_DIALECT;
  }

  $self->_set_json_schema_dialect($json_schema_dialect);

  # traverse an empty schema with this metaschema uri to confirm it is valid
  my $check_metaschema_state = $evaluator->traverse({}, {
    metaschema_uri => $json_schema_dialect,
    initial_schema_uri => $self->canonical_uri->clone->fragment('/jsonSchemaDialect'),
  });

  @{$state}{qw(spec_version vocabularies)} = @{$check_metaschema_state}{qw(spec_version vocabularies)};

  if (@{$check_metaschema_state->{errors}}) {
    push @{$state->{errors}}, @{$check_metaschema_state->{errors}};
    return $state;
  }

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

=head1 ATTRIBUTES

These values are all passed as arguments to the constructor.

This class inherits all options from L<JSON::Schema::Modern::Document> and implements the following new ones:

=head2 evaluator

=for stopwords metaschema schemas

A L<JSON::Schema::Modern> object. Unlike in the parent class, this is B<REQUIRED>, because loaded
vocabularies, metaschemas and resource identifiers must be stored here as they are discovered in the
OpenAPI document. This is the object that will be used for subsequent evaluation of data against
schemas in the document, either manually or perhaps via a web framework plugin (coming soon).

=head2 json_schema_dialect

The URI of the metaschema to use for all embedded L<JSON Schemas|https://json-schema.org/> in the
document.

Overrides the value of C<jsonSchemaDialect> in the document, or the specification default
(C<https://spec.openapis.org/oas/3.1/dialect/base>).

If you specify your own dialect here or in C<jsonSchemaDialect>, then you need to add the
vocabularies and schemas to the implementation yourself. (see C<JSON::Schema::Modern/add_vocabulary>
and C<JSON::Schema::Modern/add_schema>).

Note this is B<NOT> the same as L<JSON::Schema::Modern::Document/metaschema_uri>, which contains the
URI describing the entire document (and is not a metaschema in this case, as the entire document is
not a JSON Schema). Note that you may need to explicitly set that attribute as well if you change
C<json_schema_dialect>, as the default metaschema used by the default C<metaschema_uri> can no
longer be assumed.

=cut
