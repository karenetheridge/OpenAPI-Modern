use strictures 2;
package JSON::Schema::Modern::Document::OpenAPI;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: One OpenAPI v3.1 or v3.2 document
# KEYWORDS: JSON Schema data validation request response OpenAPI

our $VERSION = '0.101';

use 5.020;
use utf8;
use Moo;
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
use JSON::Schema::Modern::Utilities qw(E canonical_uri jsonp is_equal json_pointer_type assert_keyword_type assert_uri_reference);
use OpenAPI::Modern::Utilities qw(:constants add_vocab_and_default_schemas load_bundled_document);
use Carp qw(croak carp);
use Digest::MD5 'md5_hex';
use Storable 'dclone';
use Ref::Util 'is_plain_hashref';
use builtin::compat 'blessed';
use MooX::TypeTiny 0.002002;
use Types::Standard qw(HashRef Str);
use namespace::clean;

extends 'JSON::Schema::Modern::Document';

our @CARP_NOT = qw(Sereal Sereal::Decoder JSON::Schema::Modern::Document);

has '+schema' => (
  isa => HashRef,
);

# json pointer => entity name (indexed by integer); overrides parent
# these aren't all the different types of objects; for now we only track those that are the valid
# target of a $ref keyword in an openapi document.
sub __entities { qw(schema response parameter example request-body header security-scheme link callbacks path-item media-type) }

# operationId => document path
has _operationIds => (
  is => 'ro',
  isa => HashRef[json_pointer_type],
  lazy => 1,
  default => sub { {} },
);

*get_operationId_path = \&operationId_path; # deprecated

sub operationId_path { $_[0]->_operationIds->{$_[1]} }
sub _add_operationId { $_[0]->_operationIds->{$_[1]} = json_pointer_type->($_[2]) }

# the minor.major version of the OpenAPI specification used for this document
has oas_version => (
  is => 'rwp',
  isa => Str->where(q{/^[1-9]\.(?:0|[1-9][0-9]*)$/}),
);

# we define the sub directly, rather than using an 'around', since our root base class is not
# Moo::Object, so we never got a BUILDARGS to modify
sub BUILDARGS ($class, @args) {
  my $args = $class->Moo::Object::BUILDARGS(@args); # we do not inherit from Moo::Object

  carp 'json_schema_dialect has been removed as a constructor attribute: use jsonSchemaDialect in your document instead'
    if exists $args->{json_schema_dialect};

  carp 'specification_version argument is ignored by this subclass: use jsonSchemaDialect in your document instead'
    if defined(delete($args->{specification_version}));

  return $args;
}

# (probably) temporary, until the parent class evaluator is completely removed
sub evaluator { die 'improper attempt to use of document evaluator' }

# called by this class's base class constructor, in order to validate the integrity of the document
# and identify all important details about this document, such as entity locations, referenceable
# identifiers, operationIds, etc.
sub traverse ($self, $evaluator, $config_override = {}) {
  croak join(', ', sort keys %$config_override), ' not supported as a config override in traverse'
    if keys %$config_override;

  my $schema = $self->schema;

  croak 'missing openapi version' if not exists $schema->{openapi};
  croak 'bad openapi version: "', $schema->{openapi}//'', '"'
    if ($schema->{openapi}//'') !~ /^[0-9]+\.[0-9]+\.[0-9]+(-.+)?$/;

  my @oad_version = split /[.-]/, $schema->{openapi};
  $self->_set_oas_version(join('.', @oad_version[0..1]));

  my ($max_supported) = grep {
    my @supported = split /\./;
    $supported[0] == $oad_version[0] && $supported[1] == $oad_version[1]
  } reverse SUPPORTED_OAD_VERSIONS->@*;

  croak 'unrecognized/unsupported openapi version ', $schema->{openapi} if not defined $max_supported;
  carp 'WARNING: your document was written for version ', $schema->{openapi},
      ' but this implementation has only been tested up to ', $max_supported,
      ': this may be okay but you should upgrade your OpenAPI::Modern installation soon'
    if defined $oad_version[2] and (split(/\./, $max_supported))[2] < $oad_version[2];

  add_vocab_and_default_schemas($evaluator, $self->oas_version);

  my $state = {
    traversed_keyword_path => '',
    keyword_path => '',
    data_path => '',
    errors => [],
    evaluator => $evaluator,
    identifiers => {},
    # note that this is the JSON Schema specification version, not OpenAPI version
    specification_version => $evaluator->SPECIFICATION_VERSION_DEFAULT,
    vocabularies => [],
    subschemas => [],
    depth => 0,
    traverse => 1,
  };

  if (exists $schema->{'$self'}) {
    my $state = { %$state, keyword => '$self', initial_schema_uri => Mojo::URL->new };

    if ($oad_version[0] == 3 and $oad_version[1] < 2) {
      ()= E($state, 'additional property not permitted');
      return $state;
    }

    return $state
      if not assert_keyword_type($state, $schema, 'string')
        or not assert_uri_reference($state, $schema)
        or not ($schema->{'$self'} !~ /#/ || E($state, '$self cannot contain a fragment'));
  }

  # determine canonical uri using rules from v3.2.0 §4.1.2.2.1, "Establishing the Base URI"
  $self->_set_canonical_uri($state->{initial_schema_uri} =
    Mojo::URL->new($schema->{'$self'}//())->to_abs($self->retrieval_uri));

  # /jsonSchemaDialect: https://spec.openapis.org/oas/latest#specifying-schema-dialects
  {
    if (exists $schema->{jsonSchemaDialect}) {
      my $state = { %$state, keyword => 'jsonSchemaDialect' };
      return $state
        if not assert_keyword_type($state, $schema, 'string')
          or not assert_uri_reference($state, $schema);
    }

    # v3.2.0 §4.24.7, "Specifying Schema Dialects": "If [jsonSchemaDialect] is not set, then the OAS
    # dialect schema id MUST be used for these Schema Objects."
    # v3.2.0 §4.1.2.2, "Relative References in API Description URIs": "Unless specified otherwise,
    # all fields that are URIs MAY be relative references as defined by RFC3986 Section 4.2."
    my $json_schema_dialect = exists $schema->{jsonSchemaDialect}
      ? Mojo::URL->new($schema->{jsonSchemaDialect})->to_abs($self->canonical_uri)
      : DEFAULT_DIALECT->{$self->oas_version};

    # continue to support the old strict dialect and metaschema which didn't have "3.1" in the $id
    if ($json_schema_dialect eq (STRICT_DIALECT->{3.1} =~ s{/3.1/}{/}r)) {
      $json_schema_dialect =~ s{share/\K}{3.1/};
      $schema->{jsonSchemaDialect} = $json_schema_dialect;
    }
    $self->_set_metaschema_uri($self->metaschema_uri =~ s{share/\K}{3.1/}r)
      if $self->_has_metaschema_uri and $self->metaschema_uri eq (STRICT_METASCHEMA->{3.1} =~ s{/3.1/}{/}r);

    # we used to always preload these, so we need to do it as needed for users who are using them
    load_bundled_document($evaluator, STRICT_DIALECT->{$self->oas_version})
      if $self->_has_metaschema_uri and $self->metaschema_uri eq STRICT_METASCHEMA->{$self->oas_version}
        or $json_schema_dialect eq STRICT_DIALECT->{$self->oas_version};

    # traverse an empty schema with this dialect uri to confirm it is valid, and add an entry in
    # the evaluator's _metaschema_vocabulary_classes
    my $check_metaschema_state = $evaluator->traverse({}, {
      metaschema_uri => $json_schema_dialect,
      initial_schema_uri => $self->canonical_uri->clone->fragment('/jsonSchemaDialect'),
      traversed_keyword_path => '/jsonSchemaDialect',
    });

    # we cannot continue if the metaschema is invalid
    if ($check_metaschema_state->{errors}->@*) {
      push $state->{errors}->@*, $check_metaschema_state->{errors}->@*;
      return $state;
    }

    $state->@{qw(specification_version vocabularies)} = $check_metaschema_state->@{qw(specification_version vocabularies)};
    $state->{json_schema_dialect} = $json_schema_dialect; # subsequent '$schema' keywords can still override this

    $self->_set_metaschema_uri(
          $json_schema_dialect eq DEFAULT_DIALECT->{$self->oas_version} ? DEFAULT_BASE_METASCHEMA->{$self->oas_version}
        : $self->_dynamic_metaschema_uri($json_schema_dialect, $evaluator))
      if not $self->_has_metaschema_uri;

    load_bundled_document($evaluator, STRICT_METASCHEMA->{$self->oas_version})
      if $self->_has_metaschema_uri and $self->metaschema_uri eq STRICT_METASCHEMA->{$self->oas_version};
  }

  $state->{identifiers}{$state->{initial_schema_uri}} = {
    path => '',
    canonical_uri => $state->{initial_schema_uri},
    specification_version => $state->{specification_version},
    vocabularies => $state->{vocabularies}, # reference, not copy
  };

  # evaluate the document against its metaschema to find any errors, to identify all schema
  # resources within to add to the global resource index, and to extract all operationIds
  my (@json_schema_paths, @operation_paths, %bad_path_item_refs, @additional_operations_paths, @servers_paths);
  my $result = $evaluator->evaluate(
    $schema, $self->metaschema_uri,
    {
      short_circuit => 1,
      collect_annotations => 0,
      validate_formats => 1,
      callbacks => {
        # we avoid producing errors here so we don't create extra errors for "not all additional
        # properties are valid" etc
        '$dynamicRef' => sub ($, $schema, $state) {
          # Note that if we are using the default metaschema
          # https://spec.openapis.org/oas/<version>/schema/<date>, we will only find the root of each
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

          push @additional_operations_paths, $state->{data_path}.'/additionalOperations'
            if $entity and $entity eq 'path-item' and exists $data->{additionalOperations};

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

  # v3.2.0 §4.8.1, "Patterned Fields": "Templated paths with the same hierarchy but different
  # templated names MUST NOT exist as they are identical."
  my %seen_path;
  foreach my $path (sort keys(($schema->{paths}//{})->%*)) {
    next if $path =~ '^x-';
    my %seen_names;
    # { for the editor
    foreach my $name ($path =~ m!\{([^}]+)\}!g) {
      if (++$seen_names{$name} == 2) {
        ()= E({ %$state, keyword_path => jsonp('/paths', $path) },
          'duplicate path template variable "%s"', $name);
      }
    }

    # { for the editor
    my $normalized = $path =~ s/\{[^}]+\}/\x00/r;
    if (my $first_path = $seen_path{$normalized}) {
      ()= E({ %$state, keyword_path => jsonp('/paths', $path) },
        'duplicate of templated path "%s"', $first_path);
      next;
    }
    $seen_path{$normalized} = $path;
  }

  foreach my $path_item (sort keys %bad_path_item_refs) {
    ()= E({ %$state, keyword_path => $path_item },
      'invalid keywords used adjacent to $ref in a path-item: %s', $bad_path_item_refs{$path_item});
  }

  foreach my $aop (sort @additional_operations_paths) {
    ()= E({ %$state, schema_path => $aop }, 'not-yet-supported use of additionalOperations');
  }

  my %seen_servers;
  foreach my $servers_location (reverse @servers_paths) {
    next if $seen_servers{$servers_location}++;

    my $servers = $self->get($servers_location);
    my %seen_url;

    foreach my $server_idx (0 .. $servers->$#*) {
      if ($servers->[$server_idx]{url} =~ m{(?:/$|\?|#)}) {
        ()= E({ %$state, keyword_path => jsonp($servers_location, $server_idx, 'url') },
          'server url cannot end in / or contain query or fragment components');
        next;
      }

      # { for the editor
      my $normalized = $servers->[$server_idx]{url} =~ s/\{[^}]+\}/\x00/r;
      # { for the editor
      my @url_variables = $servers->[$server_idx]{url} =~ /\{([^}]+)\}/g;

      if (my $first_url = $seen_url{$normalized}) {
        ()= E({ %$state, keyword_path => jsonp($servers_location, $server_idx, 'url') },
          'duplicate of templated server url "%s"', $first_url);
      }
      $seen_url{$normalized} = $servers->[$server_idx]{url};

      my $variables_obj = $servers->[$server_idx]{variables};
      if (not $variables_obj) {
        # missing 'variables': needs variables/$varname/default
        ()= E({ %$state, keyword_path => jsonp($servers_location, $server_idx) },
          '"variables" property is required for templated server urls') if @url_variables;
        next;
      }

      my %seen_names;
      foreach my $name (@url_variables) {
        ()= E({ %$state, keyword_path => jsonp($servers_location, $server_idx) },
            'duplicate servers template variable "%s"', $name)
          if ++$seen_names{$name} == 2;

        ()= E({ %$state, keyword_path => jsonp($servers_location, $server_idx, 'variables') },
            'missing "variables" definition for servers template variable "%s"', $name)
          if $seen_names{$name} == 1 and not exists $variables_obj->{$name};
      }

      foreach my $varname (keys $variables_obj->%*) {
        ()= E({ %$state, keyword_path => jsonp($servers_location, $server_idx, 'variables', $varname, 'default') },
            'servers default is not a member of enum')
          if exists $variables_obj->{$varname}{enum}
            and not grep $variables_obj->{$varname}{default} eq $_, $variables_obj->{$varname}{enum}->@*;
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

  $self->_traverse_schema({ %$state, keyword_path => $_ }) foreach reverse @real_json_schema_paths;
  $self->_add_entity_location($_, 'schema') foreach $state->{subschemas}->@*;

  foreach my $pair (@operation_paths) {
    my ($operation_id, $path) = @$pair;
    if (my $existing = $self->operationId_path($operation_id)) {
      ()= E({ %$state, keyword_path => $path .'/operationId' },
        'duplicate of operationId at %s', $existing);
    }
    else {
      $self->_add_operationId($operation_id => $path);
    }
  }

  return $state;
}

# just like the base class's version, except we skip the evaluate step because we already did
# that as part of traverse.
sub validate ($class, @args) {
  my $document = blessed($class) ? $class : $class->new(@args);
  return JSON::Schema::Modern::Result->new(valid => !$document->has_errors, errors => [ $document->errors ]);
}

######## NO PUBLIC INTERFACES FOLLOW THIS POINT ########

# https://spec.openapis.org/oas/latest#schema-object
# traverse this JSON Schema and identify all errors, subschema locations, and referenceable
# identifiers
sub _traverse_schema ($self, $state) {
  my $schema = $self->get($state->{keyword_path});
  return if not is_plain_hashref($schema) or not keys %$schema;

  my $subschema_state = $state->{evaluator}->traverse($schema, {
    initial_schema_uri => canonical_uri($state),
    traversed_keyword_path => $state->{traversed_keyword_path}.$state->{keyword_path},
    metaschema_uri => $state->{json_schema_dialect},  # can be overridden with the '$schema' keyword
  });

  push $state->{errors}->@*, $subschema_state->{errors}->@*;
  push $state->{subschemas}->@*, $subschema_state->{subschemas}->@*;

  foreach my $new_uri (sort keys $subschema_state->{identifiers}->%*) {
    if (not $state->{identifiers}{$new_uri}) {
      $state->{identifiers}{$new_uri} = $subschema_state->{identifiers}{$new_uri};
      next;
    }

    my $existing = $state->{identifiers}{$new_uri};
    my $new = $subschema_state->{identifiers}{$new_uri};

    if (not is_equal(
        { canonical_uri => $new->{canonical_uri}.'', map +($_ => $new->{$_}), qw(path specification_version vocabularies) },
        { canonical_uri => $existing->{canonical_uri}.'', map +($_ => $existing->{$_}), qw(path specification_version vocabularies) })) {
      ()= E({ %$state, keyword_path => $new->{path} },
        'duplicate canonical uri "%s" found (original at path "%s")',
        $new_uri, $existing->{path});
      next;
    }

    foreach my $anchor (sort keys $new->{anchors}->%*) {
      if (my $existing_anchor = ($existing->{anchors}//{})->{$anchor}) {
        ()= E({ %$state, keyword_path => $new->{anchors}{$anchor}{path} },
          'duplicate anchor uri "%s" found (original at path "%s")',
          $new->{canonical_uri}->clone->fragment($anchor),
          $existing->{anchors}{$anchor}{path});
        next;
      }

      use autovivification 'store';
      $existing->{anchors}{$anchor} = $new->{anchors}{$anchor};
    }
  }
}

# Given a jsonSchemaDialect uri, generate a new schema that wraps the standard OAD schema
# to set the jsonSchemaDialect value for the #meta dynamic reference.
# This metaschema does not allow subschemas to select their own $schema; for that, you
# should construct your own, based on DEFAULT_BASE_METASCHEMA.
sub _dynamic_metaschema_uri ($self, $json_schema_dialect, $evaluator) {
  $json_schema_dialect .= '';
  my $dialect_uri = 'https://custom-dialect.example.com/' . md5_hex($json_schema_dialect);
  return $dialect_uri if $evaluator->_get_resource($dialect_uri);

  # we use the definition of https://spec.openapis.org/oas/<version>/schema-base/<date> but swap out
  # the dialect reference.
  my $schema = dclone($evaluator->_get_resource(DEFAULT_BASE_METASCHEMA->{$self->oas_version})->{document}->schema);
  $schema->{'$id'} = $dialect_uri;
  $schema->{'$defs'}{dialect}{const} = $json_schema_dialect;
  $schema->{'$defs'}{schema}{'$ref'} = $json_schema_dialect;

  $evaluator->add_document(
    Mojo::URL->new($dialect_uri),
    JSON::Schema::Modern::Document->new(
      schema => $schema,
      evaluator => $evaluator,
    ));

  return $dialect_uri;
}

# FREEZE is defined by parent class

# callback hook for Sereal::Decoder
sub THAW ($class, $serializer, $data) {
  delete $data->{evaluator};

  if (defined(my $dialect = delete $data->{json_schema_dialect})) {
    carp "use of no-longer-supported constructor argument: json_schema_dialect = \"$dialect\"; use \"jsonSchemaDialect\": \"...\"  in your OpenAPI document itself";
  }

  my $self = bless($data, $class);

  foreach my $attr (qw(schema _entities)) {
    croak "serialization missing attribute '$attr': perhaps your serialized data was produced for an older version of $class?"
      if not exists $self->{$attr};
  }

  return $self;
}

1;
__END__

=pod

=head1 SYNOPSIS

  use JSON::Schema::Modern::Document::OpenAPI;

  my $openapi_document = JSON::Schema::Modern::Document::OpenAPI->new(
    canonical_uri => 'https://example.com/v1/api',
    schema => decode_json(<<JSON),
{
  "openapi": "3.2.0",
  "info": {
    "title": "my title",
    "version": "1.2.3"
  },
  "components": {
  },
  "paths": {
    "/foo": {
      "get": {}
    },
    "/foo/{foo_id}": {
      "post": {}
    }
  }
}
JSON
    metaschema_uri => 'https://example.com/my_custom_metaschema',
  );

=for Pod::Coverage THAW get_operationId_path

=head1 DESCRIPTION

Provides structured parsing of an OpenAPI document, suitable as the base for more tooling such as
request and response validation, code generation or form generation.

The provided document must be a valid OpenAPI document, as specified by the schema identified by
one of:

=for :list
* for v3.2 documents:
  L<https://spec.openapis.org/oas/3.2/schema-base/2025-09-17> (which is a wrapper around
  L<https://spec.openapis.org/oas/3.2/schema/2025-09-17>),
  and the L<OpenAPI v3.2.x specification|https://spec.openapis.org/oas/v3.2>
* for v3.1 documents:
  L<https://spec.openapis.org/oas/3.1/schema-base/2025-09-15> (which is a wrapper around
  L<https://spec.openapis.org/oas/3.1/schema/2025-09-15>),
  and the L<OpenAPI v3.1.x specification|https://spec.openapis.org/oas/v3.1>

=head1 CONSTRUCTOR ARGUMENTS

Unless otherwise noted, these are also available as read-only accessors.

=head2 schema

The actual raw data representing the OpenAPI document. Required.

=head2 evaluator

=for stopwords metaschema schemas

A L<JSON::Schema::Modern> object which is used for parsing the schema of this document. This is the
object that holds all other schemas that may be used for parsing: that is, metaschemas that define
the structure of the document.

Optional, unless you are using custom metaschemas for your OpenAPI document or embedded JSON Schemas
(in which case you should define the evaluator first and call L<JSON::Schema::Modern/add_schema> for
each customization, before calling this constructor).

This argument is not saved after object construction, so it is not available as an accessor.
However, if this document object was constructed via a call to L<OpenAPI::Modern/new>, it will be
saved on that object for use during request and response validation, so it is expected that the
evaluator object should also hold the other documents that are needed for runtime evaluation (which
may be other L<JSON::Schema::Modern::Document::OpenAPI> objects).

=head2 canonical_uri

This is the identifier that the document is known by, which is used to resolve any relative C<$ref>
keywords in the document (unless overridden by a subsequent C<$id> in a schema).
See L<Specification Reference: Relative References in API Description URIs/https://spec.openapis.org/oas/latest#relative-references-in-api-description-uris>.
It is strongly recommended that this URI is absolute.

In v3.2+ documents, it is used to resolve the C<$self> value in the document itself, which then
replaces this C<canonical_uri> value.

See also L</retrieval_uri>.

=head2 metaschema_uri

The URI of the schema that describes the OpenAPI document itself. Defaults to
L<https://spec.openapis.org/oas/3.2/schema-base/2025-09-17> when the
C<L<jsonSchemaDialect/https://spec.openapis.org/oas/latest#openapi-object>>
is not changed from its default; otherwise defaults to a dynamically generated metaschema that uses
the correct value of C<jsonSchemaDialect>, so you don't need to write one yourself.

Note that both the schemas described by C<metaschema_uri> and by the C<jsonSchemaDialect> keyword
(if you are using custom schemas) should be loaded into the evaluator in advance with
L<JSON::Schema::Modern/add_schema>, and then this evaluator should be provided to the
L<OpenAPI::Modern> constructor.

=head1 METHODS

This class inherits all methods from L<JSON::Schema::Modern::Document>. In addition:

=head2 retrieval_uri

Also available as L<JSON::Schema::Modern::Document/original_uri>, this is known as the "retrieval
URI" in the OAS specification: the URL the document was originally sourced from, or the URI that
was used to add the document to the L<OpenAPI::Modern> instance.

In OpenAPI version 3.1.x (but not in 3.2+), this is the same as L</canonical_uri>.

=head2 oas_version

The C<major.minor> version of the OpenAPI specification being used; derived from the C<openapi>
field at the top of the document. Used to determine the required document format and all derived
behaviours.

Read-only.

=head2 operationId_path

  my $path = $document->operationId_path($operation_id);

Returns the json pointer location of the operation containing the provided C<operationId> (suitable
for passing to C<< $document->get(..) >>), or C<undef> if the operation does not exist in the
document.

=head1 SEE ALSO

=for :list
* L<Mojolicious::Plugin::OpenAPI::Modern>
* L<OpenAPI::Modern>
* L<JSON::Schema::Modern>
* L<JSON::Schema::Modern::Document>
* L<https://json-schema.org>
* L<https://www.openapis.org/>
* L<https://learn.openapis.org/>
* L<https://spec.openapis.org/oas/latest>
* L<https://spec.openapis.org/oas/#schema-iterations>

=cut
