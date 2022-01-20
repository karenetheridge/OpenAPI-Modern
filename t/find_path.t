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
use HTTP::Request::Common;
use YAML::PP 0.005;

my $openapi_preamble = <<'YAML';
---
openapi: 3.1.0
info:
  title: Test API
  version: 1.2.3
YAML

my $doc_uri = Mojo::URL->new('openapi.yaml');
my $yamlpp = YAML::PP->new(boolean => 'JSON::PP');

subtest 'find_path' => sub {
  my $request = GET 'http://example.com/foo/bar';
  my $openapi = OpenAPI::Modern->new(
    openapi_uri => 'openapi.yaml',
    openapi_schema => $yamlpp->load_string(<<YAML));
$openapi_preamble
paths:
  /foo/{foo_id}:
    post:
      operationId: my-post-path
  /foo/bar:
    get:
      operationId: my-get-path
webhooks:
  my_hook:
    description: I like webhooks
    post:
      operationId: hooky
YAML

  ok(!$openapi->find_path($request, my $options = { path_template => '/foo/baz', path_captures => {} }),
    'find_path returns false');

  cmp_deeply(
    $options,
    {
      path_template => '/foo/baz',
      path_captures => {},
      errors => [
        methods(TO_JSON => {
          instanceLocation => '/request/uri/path',
          keywordLocation => '/paths',
          absoluteKeywordLocation => $doc_uri->clone->fragment('/paths')->to_string,
          error => 'missing path-item "/foo/baz"',
        }),
      ],
    },
    'unsuccessful path extraction results in the error being returned in the options hash',
  );
};

done_testing;
