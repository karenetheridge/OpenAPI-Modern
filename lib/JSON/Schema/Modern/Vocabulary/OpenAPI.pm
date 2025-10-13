use strictures 2;
package JSON::Schema::Modern::Vocabulary::OpenAPI;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema OpenAPI vocabulary

our $VERSION = '0.100';

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
use JSON::Schema::Modern::Utilities qw(assert_keyword_type annotate_self E is_type jsonp);
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://spec.openapis.org/oas/3.1/vocab/base' => 'draft2020-12',
}

sub keywords {
  qw(discriminator example externalDocs xml);
}

sub _traverse_keyword_discriminator ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'object');

  # "the discriminator field MUST be a required field"
  return E($state, 'missing required property "propertyName"')
    if not exists $schema->{discriminator}{propertyName};
  return E({ %$state, _keyword_path_suffix => 'propertyName' }, 'discriminator propertyName is not a string')
    if not is_type('string', $schema->{discriminator}{propertyName});

  my $valid = 1;
  if (exists $schema->{discriminator}{mapping}) {
    return if not assert_keyword_type({ %$state, _keyword_path_suffix => 'mapping' }, $schema, 'object');
    return E({ %$state, _keyword_path_suffix => 'mapping' }, 'discriminator mapping is not an object ')
      if not is_type('object', $schema->{discriminator}{mapping});
    foreach my $mapping_key (sort keys $schema->{discriminator}{mapping}->%*) {
      my $uri = $schema->{discriminator}{mapping}{$mapping_key};
      $valid = E({ %$state, _keyword_path_suffix => [ 'mapping', $mapping_key ] }, 'discriminator mapping value for "%s" is not a string', $mapping_key), next if not is_type('string', $uri);
    }
  }

  return $valid;
}

sub _eval_keyword_discriminator ($self, $data, $schema, $state) {
  # Note: the spec is unclear of the expected behaviour when the data instance is not an object
  return 1 if not is_type('object', $data);

  my $discriminator_key = $schema->{discriminator}{propertyName};

  # property with name <propertyName> MUST be present in the data payload
  return E($state, 'missing required discriminator property "%s"', $discriminator_key)
    if not exists $data->{$discriminator_key};

  my $discriminator_value = $data->{$discriminator_key};

  if (exists $schema->{discriminator}{mapping} and exists $schema->{discriminator}{mapping}{$discriminator_value}) {
    # use 'mapping' to determine which schema to use.
    # Note that the spec uses an example that assumes that the mapping value can be appended to
    # /components/schemas/, _as well as_ being treated as a uri-reference, but this is ambiguous.
    # For now we will handle it by prepending '#/components/schemas' if it is not already a
    # fragment-only uri reference.
    my $mapping = $schema->{discriminator}{mapping}{$discriminator_value};

    return $self->eval_subschema_at_uri($data, $schema,
      { %$state, keyword => $state->{keyword}.jsonp('', 'mapping', $discriminator_value) },
      Mojo::URL->new($mapping =~ /^#/ ? $mapping : '#/components/schemas/'.$mapping)->to_abs($state->{initial_schema_uri}),
    );
  }
  elsif ($state->{document}->get_entity_at_location('/components/schemas/'.$discriminator_value) eq 'schema') {
    return $self->eval_subschema_at_uri($data, $schema, { %$state, keyword => $state->{keyword}.'/propertyName' },
      Mojo::URL->new->fragment(jsonp('/components/schemas', $discriminator_value))->to_abs($state->{initial_schema_uri}),
    );
  }
  else {
    # §4.8.25.4: "If the discriminator value does not match an implicit or explicit mapping, no
    # schema can be determined and validation SHOULD fail."
    return E({ %$state, data_path => jsonp($state->{data_path}, $discriminator_key) },
      'invalid %s: "%s"', $discriminator_key, $discriminator_value);
  }
}

sub _traverse_keyword_example { 1 }

sub _eval_keyword_example ($self, $data, $schema, $state) {
  annotate_self($state, $schema);
}

# until we do something with these values, we do not bother checking the structure
sub _traverse_keyword_externalDocs { 1 }

sub _eval_keyword_externalDocs { goto \&_eval_keyword_example }

# until we do something with these values, we do not bother checking the structure
sub _traverse_keyword_xml { 1 }

sub _eval_keyword_xml { goto \&_eval_keyword_example }

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema "OpenAPI" vocabulary, indicated in metaschemas
with the URI C<https://spec.openapis.org/oas/3.1/vocab/base> and formally specified in
L<https://spec.openapis.org/oas/v3.1#schema-object>.

This vocabulary is normally made available by using the default OpenAPI metaschema
(currently L<https://spec.openapis.org/oas/3.1/schema/2025-09-15>).

=head1 SEE ALSO

=for :list
* L<Mojolicious::Plugin::OpenAPI::Modern>
* L<OpenAPI::Modern>
* L<JSON::Schema::Modern::Document::OpenAPI>
* L<JSON::Schema::Modern>
* L<https://json-schema.org>
* L<https://www.openapis.org/>
* L<https://learn.openapis.org/>
* L<https://spec.openapis.org/oas/v3.1>

=cut
