use strict;
use warnings;
package OpenAPI::Modern;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Validate HTTP requests and responses against an OpenAPI document
# KEYWORDS: validation evaluation JSON Schema OpenAPI Swagger HTTP request response

our $VERSION = '0.004';

use 5.020;  # for fc, unicode_strings features
use Moo;
use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Carp 'croak';
use Safe::Isa;
use Ref::Util 'is_plain_hashref';
use List::Util 'first';
use Feature::Compat::Try;
use JSON::Schema::Modern 0.527;
use JSON::Schema::Modern::Utilities qw(jsonp canonical_uri E abort);
use JSON::Schema::Modern::Document::OpenAPI;
use MooX::HandlesVia;
use MooX::TypeTiny 0.002002;
use Types::Standard 'InstanceOf';
use constant { true => JSON::PP::true, false => JSON::PP::false };
use namespace::clean;

has openapi_document => (
  is => 'ro',
  isa => InstanceOf['JSON::Schema::Modern::Document::OpenAPI'],
  required => 1,
  handles => {
    openapi_uri => 'canonical_uri', # Mojo::URL
    openapi_schema => 'schema',     # hashref
  },
);

# held separately because $document->evaluator is a weak ref
has evaluator => (
  is => 'ro',
  isa => InstanceOf['JSON::Schema::Modern'],
  required => 1,
  handles => [ qw(get_media_type add_media_type) ],
);

around BUILDARGS => sub ($orig, $class, @args) {
  my $args = $class->$orig(@args);

  if (exists $args->{openapi_document}) {
    $args->{evaluator} = $args->{openapi_document}->evaluator;
  }
  else {
    # construct document out of openapi_uri, openapi_schema, evaluator, if provided.
    croak 'missing required constructor arguments: either openapi_document, or openapi_uri'
      if not exists $args->{openapi_uri};
    croak 'missing required constructor arguments: either openapi_document, or openapi_schema'
      if not exists $args->{openapi_schema};

    $args->{evaluator} //= JSON::Schema::Modern->new(validate_formats => 1, max_traversal_depth => 80);
    $args->{openapi_document} = JSON::Schema::Modern::Document::OpenAPI->new(
      canonical_uri => $args->{openapi_uri},
      schema => $args->{openapi_schema},
      evaluator => $args->{evaluator},
    );

    $args->{evaluator}->add_schema($args->{openapi_document});
  }

  return $args;
};

# at the moment, we rely on these values being provided in $options:
# - path_template
# - path_captures
sub validate_request ($self, $request, $options) {
  my $state = {
    data_path => '/request',
    initial_schema_uri => $self->openapi_uri,   # the canonical URI as of the start or last $id, or the last traversed $ref
    traversed_schema_path => '',    # the accumulated traversal path as of the start, or last $id, or up to the last traversed $ref
    schema_path => '',              # the rest of the path, since the last $id or the last traversed $ref
    errors => [],
  };

  my $path_template = $options->{path_template};
  my $captures = $options->{path_captures};
  croak 'missing parameter path_template' if not length $path_template;
  croak 'missing parameter captures ' if not is_plain_hashref($captures);

  try {
    my $method = lc $request->method;
    my $schema = $self->openapi_document->schema;

    my $path_item = $schema->{paths}{$path_template};
    abort({ %$state, keyword => 'paths', _schema_path_suffix => $path_template },
      'missing path-item "%s"', $path_template) if not $path_item;

    $state->{schema_path} = jsonp('/paths', $path_template);
    my $operation = $path_item->{$method};
    abort({ %$state, keyword => $method }, 'missing entry for HTTP method "%s"', $method)
      if not $operation;

    # PARAMETERS
    # { $in => { $name => 'path-item'|$method } }  as we process each one.
    my $request_parameters_processed;

    # first, consider parameters at the operation level.
    # parameters at the path-item level are also considered, if not already seen at the operation level
    foreach my $section ($method, 'path-item') {
      foreach my $idx (0 .. (($section eq $method ? $operation : $path_item)->{parameters}//[])->$#*) {
        my $state = { %$state, schema_path => jsonp($state->{schema_path},
          ($section eq $method ? $method : ()), 'parameters', $idx) };
        my $param_obj = ($section eq $method ? $operation : $path_item)->{parameters}[$idx];
        while (my $ref = $param_obj->{'$ref'}) {
          $param_obj = $self->_resolve_ref($ref, $state);
        }

        my $fc_name = $param_obj->{in} eq 'header' ? fc($param_obj->{name}) : $param_obj->{name};

        abort($state, 'duplicate path parameter "%s"', $param_obj->{name})
          if ($request_parameters_processed->{$param_obj->{in}}{$fc_name} // '') eq $section;
        next if exists $request_parameters_processed->{$param_obj->{in}}{$fc_name};
        $request_parameters_processed->{$param_obj->{in}}{$fc_name} = $section;

        $state->{data_path} = jsonp($state->{data_path}, $param_obj->{in}, $param_obj->{name});
        my $valid =
            $param_obj->{in} eq 'path' ? $self->_validate_path_parameter($state, $param_obj, $captures)
          : $param_obj->{in} eq 'query' ? $self->_validate_query_parameter($state, $param_obj, $request->uri)
          : $param_obj->{in} eq 'header' ? $self->_validate_header_parameter($state, $param_obj->{name}, $param_obj, $request->headers)
          : $param_obj->{in} eq 'cookie' ? $self->_validate_cookie_parameter($state, $param_obj, $request)
          : abort($state, 'unrecognized "in" value "%s"', $param_obj->{in});
      }
    }

    if (my $body_obj = $operation->{requestBody}) {
      $state->{schema_path} = jsonp($state->{schema_path}, $method, 'requestBody');
      $state->{data_path} = jsonp($state->{data_path}, 'body');

      while (my $ref = $body_obj->{'$ref'}) {
        $body_obj = $self->_resolve_ref($ref, $state);
      }

      if ($body_obj->{required} and not length($request->content_ref->$*)) {
        ()= E({ %$state, keyword => 'required' }, 'request body is required but missing');
      }
      else {
        ()= $self->_validate_body_content($state, $body_obj->{content}, $request);
      }
    }
  }
  catch ($e) {
    if ($e->$_isa('JSON::Schema::Modern::Result')) {
      return $e;
    }
    elsif ($e->$_isa('JSON::Schema::Modern::Error')) {
      push @{$state->{errors}}, $e;
    }
    else {
      E($state, 'EXCEPTION: '.$e);
    }
  }

  return $self->_result($state);
}

# at the moment, we rely on these values being provided in $options:
# - path_template
sub validate_response ($self, $response, $options) {
  my $state = {
    data_path => '/response',
    initial_schema_uri => $self->openapi_uri,   # the canonical URI as of the start or last $id, or the last traversed $ref
    traversed_schema_path => '',    # the accumulated traversal path as of the start, or last $id, or up to the last traversed $ref
    schema_path => '',              # the rest of the path, since the last $id or the last traversed $ref
    errors => [],
  };

  my $path_template = $options->{path_template};
  croak 'missing parameter path_template' if not length $path_template;

  try {
    my $schema = $self->openapi_document->schema;
    abort({ %$state, keyword => 'paths', _schema_path_suffix => $path_template },
        'missing path-item "%s"', $path_template)
      if not $schema->{paths}{$path_template};

    $state->{schema_path} = jsonp('/paths', $path_template);
    my $method = lc $response->request->method;
    my $operation = $schema->{paths}{$path_template}{$method};
    abort({ %$state, _schema_path_suffix => $method }, 'missing operation')
      if not $operation;

    return $self->_result($state) if not exists $operation->{responses};

    $state->{schema_path} = jsonp($state->{schema_path}, $method);

    my $response_property = first { exists $operation->{responses}{$_} }
      $response->code, substr(sprintf('%03s', $response->code), 0, -2).'XX', 'default';

    if (not $response_property) {
      ()= E({ %$state, keyword => 'responses' }, 'no response object found for code %s', $response->code);
      return $self->_result($state);
    }

    my $response_obj = $operation->{responses}{$response_property};
    $state->{schema_path} = jsonp($state->{schema_path}, 'responses', $response_property);
    while (my $ref = $response_obj->{'$ref'}) {
      $response_obj = $self->_resolve_ref($ref, $state);
    }

    foreach my $header_name (keys(($response_obj->{headers}//{})->%*)) {
      next if fc $header_name eq fc 'Content-Type';
      my $state = { %$state, schema_path => jsonp($state->{schema_path}, 'headers', $header_name) };
      my $header_obj = $response_obj->{headers}{$header_name};
      while (my $ref = $header_obj->{'$ref'}) {
        $header_obj = $self->_resolve_ref($ref, $state);
      }

      ()= $self->_validate_header_parameter({ %$state,
          data_path => jsonp($state->{data_path}, 'header', $header_name) },
        $header_name, $header_obj, $response->headers);
    }

    ()= $self->_validate_body_content({ %$state, data_path => jsonp($state->{data_path}, 'body') },
        $response_obj->{content}, $response)
      if exists $response_obj->{content};
  }
  catch ($e) {
    if ($e->$_isa('JSON::Schema::Modern::Result')) {
      return $e;
    }
    elsif ($e->$_isa('JSON::Schema::Modern::Error')) {
      push @{$state->{errors}}, $e;
    }
    else {
      E($state, 'EXCEPTION: '.$e);
    }
  }

  return $self->_result($state);
}

######## NO PUBLIC INTERFACES FOLLOW THIS POINT ########

# for now, we only use captures, rather than parsing the URI directly.
sub _validate_path_parameter ($self, $state, $param_obj, $captures) {
  return E({ %$state, keyword => 'content' }, 'content not yet supported')
    if exists $param_obj->{content};

  # 'required' must be true for path parameters
  return E({ %$state, keyword => 'required' }, 'missing path parameter: %s', $param_obj->{name})
    if not exists $captures->{$param_obj->{name}};

  $state = { %$state, schema_path => jsonp($state->{schema_path}, 'schema') };
  $self->_evaluate_subschema($captures->{$param_obj->{name}}, $param_obj->{schema}, $state);
}

sub _validate_query_parameter ($self, $state, $param_obj, $uri) {
  return E({ %$state, keyword => 'content' }, 'content not yet supported')
    if exists $param_obj->{content};

  # parse the query parameters out of uri
  my $query_params = { $uri->query_form };

  # TODO: support different styles.
  # for now, we only support style=form and do not allow for multiple values per
  # property (i.e. 'explode' is not checked at all.)
  # (other possible style values: spaceDelimited, pipeDelimited, deepObject)

  if (not exists $query_params->{$param_obj->{name}}) {
    return E({ %$state, keyword => 'required' }, 'missing query parameter: %s', $param_obj->{name})
      if $param_obj->{required};
    return 1;
  }

  # TODO: check 'allowReserved': it cannot be supported if we use proper URL encoding

  $state = { %$state, schema_path => jsonp($state->{schema_path}, 'schema') };
  $self->_evaluate_subschema($query_params->{$param_obj->{name}}, $param_obj->{schema}, $state);
}

# validates a header, from either the request or the response
sub _validate_header_parameter ($self, $state, $header_name, $header_obj, $headers) {
  return E({ %$state, keyword => 'content' }, 'content not yet supported')
    if exists $header_obj->{content};

  # NOTE: for now, we will only support a single value, as a string.
  my @values = $headers->header($header_name);
  if (not @values) {
    return E({ %$state, keyword => 'required' }, 'missing header: %s', $header_name)
      if $header_obj->{required};
    return 1;
  }

  $state = { %$state, schema_path => jsonp($state->{schema_path}, 'schema') };
  $self->_evaluate_subschema($values[0], $param_obj->{schema}, $state);
}

sub _validate_cookie_parameter ($self, $state, $param_obj, $request) {
  return E($state, 'cookie parameters not yet supported');
}

sub _validate_body_content ($self, $state, $content_obj, $message) {
  my $content_type = $message->content_type;

  # TODO: respect wildcard entries in the openapi document
  return E({ %$state, keyword => 'content' }, 'incorrect Content-Type "%s"', $content_type)
    if not exists $content_obj->{$content_type};

  if (exists $content_obj->{$content_type}{encoding}) {
    my $state = { %$state, schema_path => jsonp($state->{schema_path}, 'content', $content_type) };
    # "The key, being the property name, MUST exist in the schema as a property."
    foreach my $property (keys $content_obj->{$content_type}{encoding}->%*) {
      ()= E({ $state, schema_path => jsonp($state->{schema_path}, 'schema', 'properties', $property) },
          'encoding property "%s" requires a matching property definition in the schema')
        if not exists(($content_obj->{$content_type}{schema}{properties}//{})->{$property});
    }

    # "The encoding object SHALL only apply to requestBody objects when the media type is multipart or
    # application/x-www-form-urlencoded."
    return E({ %$state, keyword => 'encoding' }, 'encoding not yet supported')
      if $content_type =~ m{^multipart/} or $content_type eq 'application/x-www-form-urlencoded';
  }

  # undoes the Content-Encoding header
  my $decoded_content_ref = $message->decoded_content(ref => 1);

  # decode the charset
  my $charset = $message->content_charset;
  $decoded_content_ref = \ Encode::decode($charset, $decoded_content_ref->$*, Encode::FB_CROAK | Encode::LEAVE_SRC);

  my $media_type_decoder = $self->get_media_type($content_type);
  abort({ %$state, keyword => 'content', _schema_path_suffix => $content_type },
      'EXCEPTION: unsupported Content-Type "%s": add support with $openapi->add_media_type(...)', $content_type)
    if not $media_type_decoder;

  $decoded_content_ref = $media_type_decoder->($decoded_content_ref);

  $state = { %$state, schema_path => jsonp($state->{schema_path}, 'content', $content_type, 'schema') };
  $self->_evaluate_subschema($decoded_content_ref->$*, $body_obj->{content}{$content_type}{schema}, $state);
}

# wrap a result object around the errors
sub _result ($self, $state) {
  return JSON::Schema::Modern::Result->new(
    output_format => $self->evaluator->output_format,
    valid => !$state->{errors}->@*,
    !$state->{errors}->@*
      ? ($self->evaluator->collect_annotations
        ? (annotations => $state->{annotations}) : ())
      : (errors => $state->{errors}),
  );
}

sub _resolve_ref ($self, $ref, $state) {
  my $uri = Mojo::URL->new($ref)->to_abs($state->{initial_schema_uri});
  my $schema_info = $self->evaluator->_fetch_from_uri($uri);
  abort({ %$state, keyword => '$ref' }, 'EXCEPTION: unable to find resource %s', $uri)
    if not $schema_info;

  ++$state->{depth};
  $state->{initial_schema_uri} = $schema_info->{canonical_uri};
  $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path}.jsonp('/$ref');
  $state->{schema_path} = '';

  return $schema_info->{schema};
}

# evaluates data against the subschema at the current state location
sub _evaluate_subschema ($self, $data, $schema, $state) {
  return 1 if is_plain_hashref($schema) ? !keys(%$schema) : $schema; # true schema

  my $result = $self->evaluator->evaluate(
    $data, canonical_uri($state),
    {
      data_path => $state->{data_path},
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path},
    },
  );
  push $state->{errors}->@*, $result->errors;
  push $state->{annotations}->@*, $result->annotations if $self->evaluator->collect_annotations;
  return !!$result;
}

1;
__END__

=pod

=head1 SYNOPSIS

  my $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => YAML::PP->new(boolean => 'JSON::PP')->load_string(<<'YAML'),
  openapi: 3.1.0
  info:
    title: Test API
    version: 1.2.3
  paths:
    /foo/{foo_id}:
      parameters:
      - name: foo_id
        in: path
        required: true
        schema:
          pattern: ^[a-z]+$
      post:
        parameters:
        - name: My-Request-Header
          in: header
          required: true
          schema:
            pattern: ^[0-9]+$
        requestBody:
          required: true
          content:
            application/json:
              schema:
                type: object
                properties:
                  hello:
                    type: string
                    pattern: ^[0-9]+$
        responses:
          200:
            description: success
            headers:
              My-Response-Header:
                required: true
                schema:
                  pattern: ^[0-9]+$
            content:
              application/json:
                schema:
                  type: object
                  required: [ status ]
                  properties:
                    status:
                      const: ok
  YAML
  );

  say 'request:';
  my $request = HTTP::Request->new(
    POST => 'http://example.com/foo/bar',
    [ 'My-Request-Header' => '123', 'Content-Type' => 'application/json' ],
    '{"hello": 123}',
  );
  say $openapi->validate_request($request, {
    path_template => '/foo/{foo_id}',
    path_captures => { foo_id => 'bar' },
  });

  say 'response:';
  my $response = HTTP::Response->new(
    200 => 'OK',
    [ 'My-Response-Header' => '123' ],
    '{"status": "ok"}',
  );
  say $openapi->validate_response($response, '/foo/{foo_id}');

prints:

  request:
  '/request/body/hello': wrong type (expected string)
  '/request/body': not all properties are valid
  response:
  valid

=for Pod::Coverage BUILDARGS

=for :stopwords schemas jsonSchemaDialect metaschema subschema

=head1 DESCRIPTION

This module provides various tools for working with an OpenAPI Specification v3.1 document within
your application. The JSON Schema evaluator is fully specification-compliant; the OpenAPI evaluator
aims to be but some features are not yet available. My belief is that missing features are better
than features that seem to work but actually cut corners for simplicity.

=head1 CONSTRUCTOR ARGUMENTS

=head2 openapi_document

The L<JSON::Schema::Modern::Document::OpenAPI> document that holds the OpenAPI information to be
used for validation. If it is not provided to the constructor, then L</openapi_uri> and
L</openapi_schema> B<MUST> be provided, and L</evaluator> will also be used if provided.

=head2 openapi_uri

The URI that identifies the OpenAPI document.
Ignored if L</openapi_document> is provided.

=head2 openapi_schema

The data structure describing the OpenAPI v3.1 document (as specified at
L<https://spec.openapis.org/oas/v3.1.0>). Ignored if L</openapi_document> is provided.

=head2 evaluator

The L<JSON::Schema::Modern> object to use for all URI resolution and JSON Schema evaluation.
Ignored if L</openapi_document> is provided.

=head1 ACCESSORS

=head2 openapi_document

The L<JSON::Schema::Modern::Document::OpenAPI> document that holds the OpenAPI information to be
used for validation.

=head2 openapi_uri

The URI that identifies the OpenAPI document.

=head2 openapi_schema

The data structure describing the OpenAPI document. See L<the specification/https://spec.openapis.org/oas/v3.1.0>.

=head2 evaluator

The L<JSON::Schema::Modern> object to use for all URI resolution and JSON Schema evaluation.

=head1 METHODS

=head2 validate_request

  $result = $openapi->validate_request(
    $request,
    {
      path_captures => { arg1 => 1, arg2 => 2 },
      path_template => '/foo/{arg1}/bar/{arg2}',
    },
  );

Validates an L<HTTP::Request> object against the corresponding OpenAPI v3.1 specification, returning a
L<JSON::Schema::Modern::Result> object.

The second argument is a hashref that contains extra information about the request. Possible values include:

=for :list
* C<path_template>: a string representing the request URI, with placeholders in braces (e.g.
  C</pets/{petId}>); see L<https://spec.openapis.org/oas/v3.1.0#paths-object>.
* C<path_captures>: a hashref mapping placeholders in the path to their actual values in the request URI

=head2 validate_response

  $result = $openapi->validate_response(
    $response,
    {
      path_template => '/foo/{arg1}/bar/{arg2}',
    },
  );

The second argument is a hashref that contains extra information about the request. Possible values include:

=for :list
* C<path_template>: a string representing the request URI, with placeholders in braces (e.g.
  C</pets/{petId}>); see L<https://spec.openapis.org/oas/v3.1.0#paths-object>.

=head1 ON THE USE OF JSON SCHEMAS

Embedded JSON Schemas, through the use of the C<schema> keyword, are fully draft2020-12-compliant,
as per the spec, and implemented with L<JSON::Schema::Modern>. Unless overridden with the use of the
L<jsonSchemaDialect|https://spec.openapis.org/oas/v3.1.0#specifying-schema-dialects> keyword, their
metaschema is L<https://spec.openapis.org/oas/3.1/dialect/base>, which allows for use of the
OpenAPI-specific keywords (C<discriminator>, C<xml>, C<externalDocs>, and C<example>), as defined in
L<the specification/https://spec.openapis.org/oas/v3.1.0#schema-object>. Format validation is turned
B<on>, and the use of content* keywords is off (see
L<JSON::Schema::Modern/validate_content_schemas>).

References (with the C<$ref>) keyword may reference any position within the entire OpenAPI document;
as such, json pointers are relative to the B<root> of the document, not the root of the subschema
itself. References to other documents are also permitted, provided those documents have been loaded
into the evaluator in advance (see L<JSON::Schema::Modern/add_schema>).

=head1 LIMITATIONS

Only certain permutations of OpenAPI specifications and are supported at this time:

=for :list
* for all parameters types, only C<explode: true> is supported
* for path parameters, only C<style: simple> is supported
* for query parameters, only C<style: form> is supported
* for header parameters, only C<style: simple> is supported
* cookie parameters are not checked at all yet
* for query and header parameters, only the first value of each name is considered
* media-type encodings in parameters are not yet supported

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Modern::Document::OpenAPI>
* L<JSON::Schema::Modern>
* L<https://json-schema.org>
* L<https://www.openapis.org/>
* L<https://oai.github.io/Documentation/>
* L<https://spec.openapis.org/oas/v3.1.0>

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|json-schema.slack.com> and L<OpenAPI Slack
server|open-api.slack.com>, which are also great resources for finding help.

=cut
