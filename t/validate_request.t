# vim: set ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
use 5.020;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use utf8;
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More;
use Test::Deep;
use Test::Fatal;
use OpenAPI::Modern;
use JSON::Schema::Modern::Utilities 'jsonp';
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Modern-Document-OpenAPI' => 'share' } };
use constant { true => JSON::PP::true, false => JSON::PP::false };
use HTTP::Request;
use YAML::PP;

my $path_template = '/foo/{foo_id}/bar/{bar_id}';

my $openapi_preamble = <<'YAML';
---
openapi: 3.1.0
info:
  title: Test API
  version: 1.2.3
YAML

my $doc_uri = Mojo::URL->new('openapi.yaml');

subtest 'validation errors' => sub {
  my $request = HTTP::Request->new(
    POST => 'http://example.com/some/path',
  );
  my $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths: {}
YAML
    },
  );

  like(
    exception { $openapi->validate_request($request, {}) },
    qr/^missing option path_template at /,
    'path_template is required',
  );

  like(
    exception { $openapi->validate_request($request, { path_template => $path_template }) },
    qr/^missing option path_captures at /,
    'path_captures is required',
  );

  cmp_deeply(
    (my $result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {} }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}'),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}'))->to_string,
          error => 'missing path-item "/foo/{foo_id}/bar/{bar_id}"',
        },
      ],
    },
    'path template does not exist under /paths',
  );

  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}/bar/{bar_id}: {}
YAML
    },
  );
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {}}))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', 'post'),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', 'post'))->to_string,
          error => 'missing entry for HTTP method "post"',
        },
      ],
    },
    'operation does not exist under /paths/<path-template>',
  );

  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post: {}
YAML
    },
  );
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {}}))->TO_JSON,
    { valid => true },
    'operation can be empty',
  );

  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post:
      parameters:
      - \$ref: '#/i_do_not_exist'
YAML
    },
  );
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {}}))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 $ref)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 $ref)))->to_string,
          error => 'EXCEPTION: unable to find resource openapi.yaml#/i_do_not_exist',
        },
      ],
    },
    'bad $ref in operation parameters',
  );

  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}/bar/{bar_id}:
    parameters:
    - \$ref: '#/i_do_not_exist'
    post: {}
YAML
    },
  );
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {}}))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(parameters 0 $ref)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(parameters 0 $ref)))->to_string,
          error => 'EXCEPTION: unable to find resource openapi.yaml#/i_do_not_exist',
        },
      ],
    },
    'bad $ref in path-item parameters',
  );

  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
components:
  parameters:
    foo:
      \$ref: '#/i_do_not_exist'
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post:
      parameters:
      - \$ref: '#/components/parameters/foo'
YAML
      },
  );
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {}}))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 $ref $ref)),
          absoluteKeywordLocation => $doc_uri->clone->fragment('/components/parameters/foo/$ref')->to_string,
          error => 'EXCEPTION: unable to find resource openapi.yaml#/i_do_not_exist',
        },
      ],
    },
    'bad $ref to $ref in operation parameters',
  );

  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post:
      parameters:
      - name: yum
        in: cookie
        required: false
        schema:
          type: string
YAML
    },
  );
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {}}))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/cookie/yum',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0)))->to_string,
          error => 'cookie parameters not yet supported',
        },
      ],
    },
    'cookies are not yet supported',
  );

  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
components:
  parameters:
    foo-header:
      name: Foo-Bar
      in: header
      required: true
      schema:
        pattern: ^[0-9]+\$
paths:
  /foo/{foo_id}/bar/{bar_id}:
    parameters:
    - name: FOO-BAR   # different case, but should still be overridden by the operation parameter
      in: header
      required: true
      schema: true
    post:
      parameters:
      - name: foo_id
        in: path
        required: true
        schema:
          pattern: ^[0-9]+\$
      - name: alpha
        in: query
        required: true
        schema:
          pattern: ^[0-9]+\$
      - \$ref: '#/components/parameters/foo-header'
      - name: beta
        in: query
        required: false
        schema: false
      - name: gamma
        in: query
        required: false
        content:
          unknown/encodingtype:
            schema: true
      - name: delta
        in: query
        required: false
        content:
          unknown/encodingtype:
            schema: false
YAML
    },
    # note that bar_id is not listed as a path parameter
  );
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => { bar_id => 'bar' } }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/path/foo_id',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 required)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 required)))->to_string,
          error => 'missing path parameter: foo_id',
        },
        {
          instanceLocation => '/request/query/alpha',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 1 required)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 1 required)))->to_string,
          error => 'missing query parameter: alpha',
        },
        {
          instanceLocation => '/request/header/Foo-Bar',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 2 $ref required)),
          absoluteKeywordLocation => $doc_uri->clone->fragment('/components/parameters/foo-header/required')->to_string,
          error => 'missing header: Foo-Bar',
        },
      ],
    },
    'path, query and header parameters are missing; header names are case-insensitive',
  );


  $request->uri($request->uri.'?alpha=1&gamma=foo&delta=bar');
  $request->header('Foo-Bar' => 1);
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => { foo_id => '1' } }))->TO_JSON, # string, treated as int
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/query/delta',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 5 content unknown/encodingtype)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 5 content unknown/encodingtype)))->to_string,
          error => 'EXCEPTION: unsupported Content-Type "unknown/encodingtype": add support with $openapi->add_media_type(...)',
        },
      ],
    },
    'a missing media-type is not an error if the schema is a no-op true schema',
  );


  $request->uri('http://example.com/some/path?alpha=hello&beta=3.1415');
  $request->headers->header('FOO-BAR' => 'header value');    # exactly matches path parameter
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => { foo_id => 'foo', bar_id => 'bar' } }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/path/foo_id',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 schema pattern)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 schema pattern)))->to_string,
          error => 'pattern does not match',
        },
        {
          instanceLocation => '/request/query/alpha',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 1 schema pattern)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 1 schema pattern)))->to_string,
          error => 'pattern does not match',
        },
        {
          instanceLocation => '/request/header/Foo-Bar',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 2 $ref schema pattern)),
          absoluteKeywordLocation => $doc_uri->clone->fragment('/components/parameters/foo-header/schema/pattern')->to_string,
          error => 'pattern does not match',
        },
        {
          instanceLocation => '/request/query/beta',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 3 schema)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 3 schema)))->to_string,
          error => 'subschema is false',
        },
      ],
    },
    'path, query and header parameters are evaluated against their schemas',
  );


  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post:
      parameters:
      - name: foo_id
        in: path
        required: true
        content:
          application/json:
            schema:
              required: ['key']
      - name: query1
        in: query
        required: true
        content:
          application/json:
            schema:
              required: ['key']
      - name: Header1
        in: header
        required: true
        content:
          application/json:
            schema:
              required: ['key']
YAML
      },
  );

  $request->uri('http://example.com/some/path?query1={corrupt json');
  $request->header('Header1' => '{corrupt json');
  cmp_deeply(
    $result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => { foo_id => '{corrupt json' } })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/path/foo_id',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 content application/json)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 content application/json)))->to_string,
          error => 'could not decode content as application/json',
        },
        {
          instanceLocation => '/request/query/query1',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 1 content application/json)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 1 content application/json)))->to_string,
          error => 'could not decode content as application/json',
        },
        {
          instanceLocation => '/request/header/Header1',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 2 content application/json)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 2 content application/json)))->to_string,
          error => 'could not decode content as application/json',
        },
      ],
    },
    'errors during media-type decoding are detected',
  );


  $request->uri('http://example.com/some/path?query1={"hello":"there"}');
  $request->header('Header1' => '{"hello":"there"}');
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => { foo_id => '{"hello":"there"}'}}))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/path/foo_id',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 content application/json schema required)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 content application/json schema required)))->to_string,
          error => 'missing property: key',
        },
        {
          instanceLocation => '/request/query/query1',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 1 content application/json schema required)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 1 content application/json schema required)))->to_string,
          error => 'missing property: key',
        },
        {
          instanceLocation => '/request/header/Header1',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 2 content application/json schema required)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 2 content application/json schema required)))->to_string,
          error => 'missing property: key',
        },
      ],
    },
    'parameters are decoded using the indicated media type and then validated against the content schema',
  );


  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}/bar/{bar_id}:
    parameters:
    - name: foo_id
      in: path
      required: true
      schema:
        pattern: ^[0-9]+\$
    - name: bar_id
      in: path
      required: true
      schema:
        pattern: ^[0-9]+\$
    post:
      parameters:
      - name: foo_id
        in: path
        required: true
        schema:
          maxLength: 1
      - name: bar_id
        in: query
        required: false
        schema:
          maxLength: 1
YAML
      },
  );

  $request->uri('http://example.com/some/path');
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => { foo_id => 'foo', bar_id => 'bar' } }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/path/foo_id',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 schema maxLength)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0 schema maxLength)))->to_string,
          error => 'length is greater than 1',
        },
        {
          instanceLocation => '/request/path/bar_id',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(parameters 1 schema pattern)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(parameters 1 schema pattern)))->to_string,
          error => 'pattern does not match',
        },
      ],
    },
    'path parameters: operation overshadows path-item',
  );


  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post:
      requestBody:
        \$ref: '#/i_do_not_exist'
YAML
    },
  );

  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {} }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody $ref)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody $ref)))->to_string,
          error => 'EXCEPTION: unable to find resource openapi.yaml#/i_do_not_exist',
        },
      ],
    },
    'bad $ref in requestBody',
  );


  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post:
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                alpha:
                  type: string
                  pattern: ^[0-9]+\$
                beta:
                  type: string
                  const: éclair
                gamma:
                  type: string
                  const: ಠ_ಠ
              additionalProperties: false
          text/html:
            schema: false
YAML
    },
  );

  # note: no content!
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {} }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody required)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody required)))->to_string,
          error => 'request body is required but missing',
        },
      ],
    },
    'request body is missing',
  );


  $request->content_type('text/plain');
  $request->content('plain text');
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {} }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content)))->to_string,
          error => 'incorrect Content-Type "text/plain"',
        },
      ],
    },
    'wrong Content-Type',
  );


  $request->content_type('text/html');
  $request->content('html text');
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {} }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content text/html)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content text/html)))->to_string,
          error => 'EXCEPTION: unsupported Content-Type "text/html": add support with $openapi->add_media_type(...)',
        },
      ],
    },
    'unsupported Content-Type',
  );


  $request->content_type('application/json; charset=UTF-8');
  $request->content('{"alpha": "123", "beta": "'.chr(0xe9).'clair"}');
  cmp_deeply(
    $result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {} })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content application/json)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content application/json)))->to_string,
          error => 'could not decode content as UTF-8',
        },
      ],
    },
    'errors during charset decoding are detected',
  );


  $request->content('{corrupt json');
  cmp_deeply(
    $result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {} })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content application/json)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content application/json)))->to_string,
          error => 'could not decode content as application/json',
        },
      ],
    },
    'errors during media-type decoding are detected',
  );


  $request->content_type('application/json; charset=ISO-8859-1');
  $request->content('{"alpha": "123", "beta": "'.chr(0xe9).'clair"}');
  cmp_deeply(
    $result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {} })->TO_JSON,
    { valid => true },
    'content matches',
  );


  $request->content_type('application/json; charset=UTF-8');
  $request->content('{"alpha": "foo", "gamma": "o.o"}');
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {} }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/body/alpha',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content application/json schema properties alpha pattern)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content application/json schema properties alpha pattern)))->to_string,
          error => 'pattern does not match',
        },
        {
          instanceLocation => '/request/body/gamma',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content application/json schema properties gamma const)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content application/json schema properties gamma const)))->to_string,
          error => 'value does not match',
        },
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content application/json schema properties)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post requestBody content application/json schema properties)))->to_string,
          error => 'not all properties are valid',
        },
      ],
    },
    'decoded content does not match the schema',
  );


  my $disapprove = v224.178.160.95.224.178.160; # utf-8-encoded "ಠ_ಠ"
  $request->content('{"alpha": "123", "gamma": "'.$disapprove.'"}');
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {} }))->TO_JSON,
    { valid => true },
    'decoded content matches the schema',
  );
};

subtest 'document errors' => sub {
  my $request = HTTP::Request->new(
    POST => 'http://example.com/some/path',
  );
  my $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
components:
  parameters:
    foo:
      name: foo_id
      in: path
      required: true
      schema: {}
paths:
  /foo/{foo_id}:
    parameters:
    - \$ref: '#/components/parameters/foo'
    - \$ref: '#/components/parameters/foo'
    post: {}
YAML
    },
  );
  cmp_deeply(
    (my $result = $openapi->validate_request($request,
      { path_template => '/foo/{foo_id}', path_captures => { foo_id => 123 }}))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(parameters 1 $ref)),
          absoluteKeywordLocation => $doc_uri->clone->fragment('/components/parameters/foo')->to_string,
          error => 'duplicate path parameter "foo_id"',
        },
      ],
    },
    'duplicate path parameters in path-item section',
  );

  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
components:
  parameters:
    foo:
      name: foo_id
      in: path
      required: true
      schema: {}
paths:
  /foo/{foo_id}:
    post:
      parameters:
      - \$ref: '#/components/parameters/foo'
      - \$ref: '#/components/parameters/foo'
YAML
    },
  );
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => '/foo/{foo_id}', path_captures => { foo_id => 123 }}))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(post parameters 1 $ref)),
          absoluteKeywordLocation => $doc_uri->clone->fragment('/components/parameters/foo')->to_string,
          error => 'duplicate path parameter "foo_id"',
        },
      ],
    },
    'duplicate path parameters in path-item section',
  );
};

subtest 'type handling of values for evaluation' => sub {
  my $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}:
    parameters:
    - name: foo_id
      in: path
      required: true
      schema:
        pattern: ^[a-z]\$
    post:
      parameters:
      - name: bar
        in: query
        required: false
        schema:
          pattern: ^[a-z]\$
      - name: Foo-Bar
        in: header
        required: false
        schema:
          pattern: ^[a-z]\$
      requestBody:
        required: true
        content:
          text/plain:
            schema:
              pattern: ^[a-z]\$
YAML
      },
  );

  my $request = HTTP::Request->new(POST => 'http://example.com/foo/123');
  $request->uri($request->uri.'?bar=456');
  $request->header('Foo-Bar' => 789);
  $request->content_type('text/plain');
  $request->content(666);

  cmp_deeply(
    (my $result = $openapi->validate_request($request,
      { path_template => '/foo/{foo_id}', path_captures => { foo_id => 123 } }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/query/bar',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(post parameters 0 schema pattern)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(post parameters 0 schema pattern)))->to_string,
          error => 'pattern does not match',
        },
        {
          instanceLocation => '/request/header/Foo-Bar',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(post parameters 1 schema pattern)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(post parameters 1 schema pattern)))->to_string,
          error => 'pattern does not match',
        },
        {
          instanceLocation => '/request/path/foo_id',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(parameters 0 schema pattern)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(parameters 0 schema pattern)))->to_string,
          error => 'pattern does not match',
        },
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(post requestBody content text/plain schema pattern)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(post requestBody content text/plain schema pattern)))->to_string,
          error => 'pattern does not match',
        },
      ],
    },
    'numeric values are treated as strings by default',
  );


  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}:
    parameters:
    - name: foo_id
      in: path
      required: true
      schema:
        type: number
        maximum: 10
    post:
      parameters:
      - name: bar
        in: query
        required: false
        schema:
          type: integer
          maximum: 10
      - name: Foo-Bar
        in: header
        required: false
        schema:
          type: number
          maximum: 10
      requestBody:
        required: true
        content:
          text/plain:
            schema:
              type: number
              maximum: 10
YAML
      },
  );

  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => '/foo/{foo_id}', path_captures => { foo_id => 123 } }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/query/bar',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(post parameters 0 schema maximum)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(post parameters 0 schema maximum)))->to_string,
          error => 'value is larger than 10',
        },
        {
          instanceLocation => '/request/header/Foo-Bar',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(post parameters 1 schema maximum)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(post parameters 1 schema maximum)))->to_string,
          error => 'value is larger than 10',
        },
        {
          instanceLocation => '/request/path/foo_id',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(parameters 0 schema maximum)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(parameters 0 schema maximum)))->to_string,
          error => 'value is larger than 10',
        },
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(post requestBody content text/plain schema maximum)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(post requestBody content text/plain schema maximum)))->to_string,
          error => 'value is larger than 10',
        },
      ],
    },
    'numeric values are treated as numbers when explicitly type-checked as numbers',
  );


  $request = HTTP::Request->new(POST => 'http://example.com/foo/9');
  $request->content_type('text/plain');
  my $val = 20; my $str = sprintf("%s\n", $val);
  $request->content($val);
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => '/foo/{foo_id}', path_captures => { foo_id => 9 } }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(post requestBody content text/plain schema maximum)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(post requestBody content text/plain schema maximum)))->to_string,
          error => 'value is larger than 10',
        },
      ],
    },
    'ambiguously-typed numbers are still handled gracefully',
  );


  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}:
    post:
      requestBody:
        required: false
        content:
          text/plain:
            schema:
              minLength: 10
YAML
      },
  );
  $request = HTTP::Request->new(POST => 'http://example.com/some/path');
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => '/foo/{foo_id}', path_captures => { foo_id => 123 } }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/header/Content-Type',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(post requestBody content)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(post requestBody content)))->to_string,
          error => 'missing header: Content-Type',
        },
      ],
    },
    'missing Content-Type does not cause an exception',
  );


  $request->content_type('text/plain');
  cmp_deeply(
    ($result = $openapi->validate_request($request,
      { path_template => '/foo/{foo_id}', path_captures => { foo_id => 123 } }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}', qw(post requestBody content text/plain schema minLength)),
          absoluteKeywordLocation => $doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}', qw(post requestBody content text/plain schema minLength)))->to_string,
          error => 'length is less than 10',
        },
      ],
    },
    'missing body does not cause an exception',
  );
};

subtest 'max_depth' => sub {
  my $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    evaluator => JSON::Schema::Modern->new(max_traversal_depth => 15),
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
components:
  parameters:
    foo:
      \$ref: '#/components/parameters/bar'
    bar:
      \$ref: '#/components/parameters/foo'
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post:
      parameters:
      - \$ref: '#/components/parameters/foo'
YAML
    },
  );
  my $request = HTTP::Request->new(POST => 'http://example.com/some/path');
  cmp_deeply(
    (my $result = $openapi->validate_request($request,
      { path_template => $path_template, path_captures => {}}))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/request',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post parameters 0), ('$ref')x16),
          absoluteKeywordLocation => $doc_uri->clone->fragment('/components/parameters/bar')->to_string,
          error => 'EXCEPTION: maximum evaluation depth exceeded',
        },
      ],
    },
    'bad $ref in operation parameters',
  );
};

done_testing;
