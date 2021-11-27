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
use OpenAPI::Modern;
use JSON::Schema::Modern::Utilities 'jsonp';
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Modern-Document-OpenAPI' => 'share' } };
use constant { true => JSON::PP::true, false => JSON::PP::false };
use HTTP::Request;
use HTTP::Response;
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
  my $response = HTTP::Response->new(404);
  $response->request(my $request = HTTP::Request->new(POST => 'http://example.com/some/path'));
  my $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths: {}
YAML
    },
  );
  cmp_deeply(
    (my $result = $openapi->validate_response($response,
      { path_template => $path_template }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/response',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}'),
          absoluteKeywordLocation => str($doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}'))),
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
    ($result = $openapi->validate_response($response, { path_template => $path_template }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/response',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', 'post'),
          absoluteKeywordLocation => str($doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', 'post'))),
          error => 'missing operation',
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
    ($result = $openapi->validate_response($response, { path_template => $path_template }))->TO_JSON,
    { valid => true },
    'no responses object - nothing to validate against',
  );

  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post:
      responses:
        200:
          description: success
        2XX:
          description: other success
YAML
    },
  );
  cmp_deeply(
    ($result = $openapi->validate_response($response, { path_template => $path_template }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/response',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post responses)),
          absoluteKeywordLocation => str($doc_uri->clone->fragment(jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post responses)))),
          error => 'no response object found for code 404',
        },
      ],
    },
    'response code not found - nothing to validate against',
  );

  $response->code(200);
  cmp_deeply(
    ($result = $openapi->validate_response($response, { path_template => $path_template }))->TO_JSON,
    { valid => true },
    'response code matched exactly',
  );

  $response->code(202);
  cmp_deeply(
    ($result = $openapi->validate_response($response, { path_template => $path_template }))->TO_JSON,
    { valid => true },
    'response code matched wildcard',
  );


  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
components:
  responses:
    foo:
      \$ref: '#/i_do_not_exist'
    default:
      description: unexpected failure
      headers:
        Content-Type:
          # this is ignored!
          required: true
          schema: {}
        Foo-Bar:
          \$ref: '#/components/headers/foo-header'
  headers:
    foo-header:
      required: true
      schema:
        pattern: ^[0-9]+\$
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post:
      responses:
        303:
          \$ref: '#/components/responses/foo'
        default:
          \$ref: '#/components/responses/default'
YAML
    },
  );
  $response->code(303);
  cmp_deeply(
    ($result = $openapi->validate_response($response, { path_template => $path_template }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/response',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post responses 303 $ref $ref)),
          absoluteKeywordLocation => str($doc_uri->clone->fragment('/components/responses/foo/$ref')),
          error => 'EXCEPTION: unable to find resource openapi.yaml#/i_do_not_exist',
        },
      ],
    },
    'bad $ref in responses',
  );

  $response->code(500);
  cmp_deeply(
    ($result = $openapi->validate_response($response, { path_template => $path_template }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/response/header/Foo-Bar',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post responses default $ref headers Foo-Bar $ref required)),
          absoluteKeywordLocation => str($doc_uri->clone->fragment('/components/headers/foo-header/required')),
          error => 'missing header: Foo-Bar',
        },
      ],
    },
    'header is missing',
  );

  $response->headers->header('FOO-BAR' => 'header value');
  cmp_deeply(
    ($result = $openapi->validate_response($response, { path_template => $path_template }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/response/header/Foo-Bar',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post responses default $ref headers Foo-Bar $ref schema pattern)),
          absoluteKeywordLocation => str($doc_uri->clone->fragment('/components/headers/foo-header/schema/pattern')),
          error => 'pattern does not match',
        },
      ],
    },
    'header is evaluated against its schema',
  );

  $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => do {
      YAML::PP->new( boolean => 'JSON::PP' )->load_string(<<YAML);
$openapi_preamble
components:
  responses:
    default:
      description: unexpected failure
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
paths:
  /foo/{foo_id}/bar/{bar_id}:
    post:
      responses:
        303:
          \$ref: '#/components/responses/foo'
        default:
          \$ref: '#/components/responses/default'
YAML
    },
  );

  $response->content_type('text/plain');
  $response->content('plain text');
  cmp_deeply(
    $result = $openapi->validate_response($response, { path_template => $path_template })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/response/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post responses default $ref content)),
          absoluteKeywordLocation => str($doc_uri->clone->fragment('/components/responses/default/content')),
          error => 'incorrect Content-Type "text/plain"',
        },
      ],
    },
    'wrong Content-Type',
  );

  $response->content_type('text/html');
  $response->content('html text');
  cmp_deeply(
    $result = $openapi->validate_response($response, { path_template => $path_template })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/response/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post responses default $ref content text/html)),
          absoluteKeywordLocation => str($doc_uri->clone->fragment(jsonp('/components/responses/default/content', 'text/html'))),
          error => 'EXCEPTION: unsupported Content-Type "text/html": add support with $openapi->add_media_type(...)',
        },
      ],
    },
    'unsupported Content-Type',
  );

  $response->content_type('application/json; charset=ISO-8859-1');
  $response->content('{"alpha": "123", "beta": "'.chr(0xe9).'clair"}');
  cmp_deeply(
    $result = $openapi->validate_response($response, { path_template => $path_template })->TO_JSON,
    { valid => true },
    'content matches',
  );

  $response->content_type('application/json; charset=UTF-8');
  $response->content('{"alpha": "foo", "gamma": "o.o"}');
  cmp_deeply(
    $result = $openapi->validate_response($response, { path_template => $path_template })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/response/body/alpha',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post responses default $ref content application/json schema properties alpha pattern)),
          absoluteKeywordLocation => str($doc_uri->clone->fragment(jsonp('/components/responses/default/content', qw(application/json schema properties alpha pattern)))),
          error => 'pattern does not match',
        },
        {
          instanceLocation => '/response/body/gamma',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post responses default $ref content application/json schema properties gamma const)),
          absoluteKeywordLocation => str($doc_uri->clone->fragment(jsonp('/components/responses/default/content', qw(application/json schema properties gamma const)))),
          error => 'value does not match',
        },
        {
          instanceLocation => '/response/body',
          keywordLocation => jsonp('/paths', '/foo/{foo_id}/bar/{bar_id}', qw(post responses default $ref content application/json schema properties)),
          absoluteKeywordLocation => str($doc_uri->clone->fragment(jsonp('/components/responses/default/content', qw(application/json schema properties)))),
          error => 'not all properties are valid',
        },
      ],
    },
    'decoded content does not match the schema',
  );


  my $disapprove = v224.178.160.95.224.178.160; # utf-8-encoded "ಠ_ಠ"
  $response->content('{"alpha": "123", "gamma": "'.$disapprove.'"}');
  cmp_deeply(
    $result = $openapi->validate_response($response, { path_template => $path_template })->TO_JSON,
    { valid => true },
    'decoded content matches the schema',
  );
};

done_testing;
