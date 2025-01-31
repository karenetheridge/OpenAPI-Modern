use strictures 2;
package JSON::Schema::Modern::Document::OpenAPI;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: One OpenAPI v3.1 document
# KEYWORDS: JSON Schema data validation request response OpenAPI

our $VERSION = '0.079';

use 5.020;
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use JSON::Schema::Modern::Utilities qw(E canonical_uri jsonp);
use Carp 'croak';
use Safe::Isa;
use File::ShareDir 'dist_dir';
use Path::Tiny;
use List::Util 'pairs';
use Ref::Util 'is_plain_hashref';
use MooX::TypeTiny 0.002002;
use Types::Standard qw(InstanceOf HashRef Str Enum);
use namespace::clean;

extends 'JSON::Schema::Modern::Document';

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

use constant DEFAULT_DIALECT => 'https://spec.openapis.org/oas/3.1/dialect/2024-10-25';
use constant DEFAULT_BASE_METASCHEMA => 'https://spec.openapis.org/oas/3.1/schema-base/2024-11-14';
use constant DEFAULT_METASCHEMA => 'https://spec.openapis.org/oas/3.1/schema/2024-11-14';

# warning: this is weak_ref'd, so it may not exist after construction/traverse time
has '+evaluator' => (
  required => 1,
);

has '+metaschema_uri' => (
  default => DEFAULT_BASE_METASCHEMA,
);

has json_schema_dialect => (
  is => 'rwp',
  isa => InstanceOf['Mojo::URL'],
  coerce => sub { $_[0]->$_isa('Mojo::URL') ? $_[0] : Mojo::URL->new($_[0]) },
);

# json pointer => entity name (indexed by integer); overrides parent
# these aren't all the different types of objects; for now we only track those that are the valid
# target of a $ref keyword in an openapi document.
sub __entities { qw(schema response parameter example request-body header security-scheme link callbacks path-item) }

# operationId => document path
has _operationIds => (
  is => 'ro',
  isa => HashRef[Str],
  lazy => 1,
  default => sub { {} },
);

sub get_operationId_path { $_[0]->_operationIds->{$_[1]} }
sub _add_operationId { $_[0]->_operationIds->{$_[1]} = Str->($_[2]) }

sub traverse ($self, $evaluator, $config_override = {}) {
  croak join(', ', sort keys %$config_override), ' not supported as a config override in traverse'
    if keys %$config_override;

  $self->_add_vocab_and_default_schemas;

  my $schema = $self->schema;
  my $state = {
    initial_schema_uri => $self->canonical_uri,
    traversed_schema_path => '',
    schema_path => '',
    data_path => '',
    errors => [],
    evaluator => $evaluator,
    identifiers => {},
    configs => {},
    # note that this is the JSON Schema specification version, not OpenAPI
    spec_version => $evaluator->SPECIFICATION_VERSION_DEFAULT,
    vocabularies => [],
    subschemas => [],
    depth => 0,
    traverse => 1,
  };

  # this is an abridged form of https://spec.openapis.org/oas/3.1/schema/2024-10-25
  # just to validate the parts of the document we need to verify before parsing jsonSchemaDialect
  # and switching to the real metaschema for this document
  state $top_schema = {
    '$schema' => 'https://json-schema.org/draft/2020-12/schema',
    type => 'object',
    required => ['openapi'],
    properties => {
      openapi => {
        type => 'string',
        pattern => '',  # just here for the callback so we can customize the error
      },
      jsonSchemaDialect => {
        type => 'string',
        format => 'uri',
      },
    },
  };
  my $top_result = $self->evaluator->evaluate(
    $schema, $top_schema,
    {
      effective_base_uri => DEFAULT_METASCHEMA,
      collect_annotations => 0,
      callbacks => {
        pattern => sub ($data, $schema, $state) {
          return $data =~ /^3\.1\.[0-9]+(-.+)?$/ ? 1 : E($state, 'unrecognized openapi version %s', $data);
        },
      },
    },
  );
  if (not $top_result->valid) {
    push $state->{errors}->@*, $top_result->errors;
    return $state;
  }

  # /jsonSchemaDialect: https://spec.openapis.org/oas/v3.1#specifying-schema-dialects
  {
    my $json_schema_dialect = $self->json_schema_dialect // $schema->{jsonSchemaDialect};

    # "If [jsonSchemaDialect] is not set, then the OAS dialect schema id MUST be used for these Schema Objects."
    $json_schema_dialect //= DEFAULT_DIALECT;

    # traverse an empty schema with this metaschema uri to confirm it is valid
    my $check_metaschema_state = $evaluator->traverse({}, {
      metaschema_uri => $json_schema_dialect,
      initial_schema_uri => $self->canonical_uri->clone->fragment('/jsonSchemaDialect'),
    });

    # we cannot continue if the metaschema is invalid
    if ($check_metaschema_state->{errors}->@*) {
      push $state->{errors}->@*, $check_metaschema_state->{errors}->@*;
      return $state;
    }

    $state->@{qw(spec_version vocabularies)} = $check_metaschema_state->@{qw(spec_version vocabularies)};
    $self->_set_json_schema_dialect($json_schema_dialect);
  }

  # evaluate the document against its metaschema to find any errors, to identify all schema
  # resources within to add to the global resource index, and to extract all operationIds
  my (@json_schema_paths, @operation_paths, %bad_path_item_refs, @servers_paths);
  my $result = $self->evaluator->evaluate(
    $schema, $self->metaschema_uri,
    {
      short_circuit => 1,
      collect_annotations => 0,
      callbacks => {
        # we avoid producing errors here so we don't create extra errors for "not all additional
        # properties are valid" etc
        '$dynamicRef' => sub ($, $schema, $state) {
          # Note that if we are using the default metaschema
          # https://spec.openapis.org/oas/3.1/schema/2024-10-25, we will only find the root of each
          # schema, not all subschemas. We will traverse each of these schemas later using
          # jsonSchemaDialect to find all subschemas and their $ids.
          push @json_schema_paths, $state->{data_path} if $schema->{'$dynamicRef'} eq '#meta';
          return 1;
        },
        '$ref' => sub ($data, $schema, $state) {
          # we only need to special-case path-item, because this is the only entity that is
          # referenced in the schema without an -or-reference
          my ($entity) = (($schema->{'$ref'} =~ m{#/\$defs/([^/]+?)(?:-or-reference)$}),
            ($schema->{'$ref'} =~ m{#/\$defs/(path-item)$}));
          $self->_add_entity_location($state->{data_path}, $entity) if $entity;

          push @operation_paths, [ $data->{operationId} => $state->{data_path} ]
            if $schema->{'$ref'} eq '#/$defs/operation' and defined $data->{operationId};

          # path-items are weird and allow mixing of fields adjacent to a $ref, which is burdensome
          # to properly support (see https://github.com/OAI/OpenAPI-Specification/issues/3734)
          if ($entity and $entity eq 'path-item' and exists $data->{'$ref'}) {
            my %path_item = $data->%*;
            delete @path_item{qw(summary description $ref)};
            $bad_path_item_refs{$state->{data_path}} = join(', ', sort keys %path_item) if keys %path_item;
          }

          # will contain duplicates; filter out later
          push @servers_paths, ($state->{data_path} =~ s{/[0-9]+$}{}r)
            if $schema->{'$ref'} eq '#/$defs/server';

          return 1;
        },
      },
    },
  );

  if (not $result->valid) {
    push $state->{errors}->@*, $result->errors;
    return $state;
  }

  # "Templated paths with the same hierarchy but different templated names MUST NOT exist as they
  # are identical."
  my %seen_path;
  foreach my $path (sort keys(($schema->{paths}//{})->%*)) {
    my %seen_names;
    foreach my $name ($path =~ m!\{([^}]+)\}!g) {
      if (++$seen_names{$name} == 2) {
        ()= E({ %$state, schema_path => jsonp('/paths', $path) },
          'duplicate path template variable "%s"', $name);
      }
    }

    my $normalized = $path =~ s/\{[^}]+\}/\x00/r;
    if (my $first_path = $seen_path{$normalized}) {
      ()= E({ %$state, schema_path => jsonp('/paths', $path) },
        'duplicate of templated path "%s"', $first_path);
      next;
    }
    $seen_path{$normalized} = $path;
  }

  foreach my $path_item (sort keys %bad_path_item_refs) {
    ()= E({ %$state, schema_path => $path_item },
      'invalid keywords used adjacent to $ref in a path-item: %s', $bad_path_item_refs{$path_item});
  }

  my %seen_servers;
  foreach my $servers_location (reverse @servers_paths) {
    next if $seen_servers{$servers_location}++;

    my $servers = $self->get($servers_location);
    my %seen_url;

    foreach my $server_idx (0 .. $servers->$#*) {
      my $normalized = $servers->[$server_idx]{url} =~ s/\{[^}]+\}/\x00/r;
      # { for the editor
      my @url_variables = $servers->[$server_idx]{url} =~ /\{([^}]+)\}/g;

      if (my $first_url = $seen_url{$normalized}) {
        ()= E({ %$state, schema_path => jsonp($servers_location, $server_idx, 'url') },
          'duplicate of templated server url "%s"', $first_url);
      }
      $seen_url{$normalized} = $servers->[$server_idx]{url};

      my $variables_obj = $servers->[$server_idx]{variables};
      if (@url_variables and not $variables_obj) {
        # missing 'variables': needs variables/$varname/default
        ()= E({ %$state, schema_path => jsonp($servers_location, $server_idx) },
          '"variables" property is required for templated server urls');
        next;
      }

      next if not $variables_obj;

      foreach my $varname (keys $variables_obj->%*) {
        if (exists $variables_obj->{$varname}{enum}
            and not grep $variables_obj->{$varname}{default} eq $_, $variables_obj->{$varname}{enum}->@*) {
          ()= E({ %$state, schema_path => jsonp($servers_location, $server_idx, 'variables', $varname, 'default') },
            'servers default is not a member of enum');
        }
      }

      if (@url_variables
          and my @missing_definitions = grep !exists $variables_obj->{$_}, @url_variables) {
        ()= E({ %$state, schema_path => jsonp($servers_location, $server_idx, 'variables') },
          'missing "variables" definition for templated variable%s "%s"',
          @missing_definitions > 1 ? 's' : '', join('", "', @missing_definitions));
      }
    }
  }

  return $state if $state->{errors}->@*;

  # disregard paths that are not the root of each embedded subschema.
  # Because the callbacks are executed after the keyword has (recursively) finished evaluating,
  # for each nested schema group. the schema paths appear longest first, with the parent schema
  # appearing last. Therefore we can whittle down to the parent schema for each group by iterating
  # through the full list in reverse, and checking if it is a child of the last path we chose to save.
  my @real_json_schema_paths;
  for (my $idx = $#json_schema_paths; $idx >= 0; --$idx) {
    next if $idx != $#json_schema_paths
      and substr($json_schema_paths[$idx], 0, length($real_json_schema_paths[-1])+1)
        eq $real_json_schema_paths[-1].'/';

    push @real_json_schema_paths, $json_schema_paths[$idx];
  }

  $self->_traverse_schema({ %$state, schema_path => $_ }) foreach reverse @real_json_schema_paths;
  $self->_add_entity_location($_, 'schema') foreach $state->{subschemas}->@*;

  foreach my $pair (@operation_paths) {
    my ($operation_id, $path) = @$pair;
    if (my $existing = $self->get_operationId_path($operation_id)) {
      ()= E({ %$state, schema_path => $path .'/operationId' },
        'duplicate of operationId at %s', $existing);
    }
    else {
      $self->_add_operationId($operation_id => $path);
    }
  }

  return $state;
}

######## NO PUBLIC INTERFACES FOLLOW THIS POINT ########

sub _add_vocab_and_default_schemas ($self) {
  my $js = $self->evaluator;
  $js->add_vocabulary('JSON::Schema::Modern::Vocabulary::OpenAPI');

  $js->add_format_validation(int32 => +{
    type => 'number',
    sub => sub ($x) {
      require Math::BigInt; Math::BigInt->VERSION(1.999701);
      $x = Math::BigInt->new($x);
      return if $x->is_nan;
      my $bound = Math::BigInt->new(2) ** 31;
      $x >= -$bound && $x < $bound;
    }
  });

  $js->add_format_validation(int64 => +{
    type => 'number',
    sub => sub ($x) {
      require Math::BigInt; Math::BigInt->VERSION(1.999701);
      $x = Math::BigInt->new($x);
      return if $x->is_nan;
      my $bound = Math::BigInt->new(2) ** 63;
      $x >= -$bound && $x < $bound;
    }
  });

  $js->add_format_validation(float => +{ type => 'number', sub => sub ($x) { 1 } });
  $js->add_format_validation(double => +{ type => 'number', sub => sub ($x) { 1 } });
  $js->add_format_validation(password => +{ type => 'string', sub => sub ($) { 1 } });

  foreach my $filename (DEFAULT_SCHEMAS->@*) {
    my $document = $js->add_schema($js->_json_decoder->decode(path(dist_dir('OpenAPI-Modern'), $filename)->slurp_raw));

    if ($document->canonical_uri =~ m{/\d{4}-\d{2}-\d{2}$}) {
      my $base = $`;
      $js->add_document($base, $document) if $base =~ m{/schema$};
      $js->add_document($base.'/latest', $document);
    }
  }
}

# https://spec.openapis.org/oas/v3.1#schema-object
sub _traverse_schema ($self, $state) {
  my $schema = $self->get($state->{schema_path});
  return if not is_plain_hashref($schema) or not keys %$schema;

  my $subschema_state = $self->evaluator->traverse($schema, {
    initial_schema_uri => canonical_uri($state),
    traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path},
    metaschema_uri => $self->json_schema_dialect,
  });

  push $state->{errors}->@*, $subschema_state->{errors}->@*;
  return if $subschema_state->{errors}->@*;

  $state->{identifiers}->@{keys $subschema_state->{identifiers}->%*} = values $subschema_state->{identifiers}->%*;
  push $state->{subschemas}->@*, $subschema_state->{subschemas}->@*;
}

# callback hook for Sereal::Decoder
sub THAW ($class, $serializer, $data) {
  foreach my $attr (qw(schema evaluator _entities)) {
    die "serialization missing attribute '$attr': perhaps your serialized data was produced for an older version of $class?"
      if not exists $class->{$attr};
  }
  bless($data, $class);
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

=for Pod::Coverage THAW

=head1 DESCRIPTION

Provides structured parsing of an OpenAPI document, suitable as the base for more tooling such as
request and response validation, code generation or form generation.

The provided document must be a valid OpenAPI document, as specified by the schema identified by
L<https://spec.openapis.org/oas/3.1/schema-base/2024-10-25>.

and the L<OpenAPI v3.1 specification|https://spec.openapis.org/oas/v3.1>.

=head1 ATTRIBUTES

These values are all passed as arguments to the constructor.

This class inherits all options from L<JSON::Schema::Modern::Document> and implements the following
new ones:

=head2 evaluator

=for stopwords metaschema schemas

A L<JSON::Schema::Modern> object. Unlike in the parent class, this is B<REQUIRED>, because loaded
vocabularies, metaschemas and resource identifiers must be stored here as they are discovered in the
OpenAPI document. This is the object that will be used for subsequent evaluation of data against
schemas in the document, either manually or perhaps via a web framework plugin (coming soon).

=head2 metaschema_uri

The URI of the schema that describes the OpenAPI document itself. Defaults to
L<https://spec.openapis.org/oas/3.1/schema-base/2024-10-25>.

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

=head1 METHODS

=head2 get_operationId_path

Returns the json pointer location of the operation containing the provided C<operationId> (suitable
for passing to C<< $document->get(..) >>), or C<undef> if the location does not exist in the
document.

=head1 SEE ALSO

=for :list
* L<Mojolicious::Plugin::OpenAPI::Modern>
* L<OpenAPI::Modern>
* L<JSON::Schema::Modern>
* L<https://json-schema.org>
* L<https://www.openapis.org/>
* L<https://learn.openapis.org/>
* L<https://spec.openapis.org/oas/v3.1>

=head1 COPYRIGHT AND LICENCE

Some schema files have their own licence, in share/oas/LICENSE.

=cut
