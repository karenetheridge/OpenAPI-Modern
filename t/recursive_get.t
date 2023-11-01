# vim: set ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::Fatal;

use lib 't/lib';
use Helper;

my $preamble = {
  openapi => '3.1.0',
  info => {
    title => 'my title',
    version => '1.2.3',
  },
};

subtest recursive_get => sub {
  my $doc = JSON::Schema::Modern::Document::OpenAPI->new(
    canonical_uri => 'http://localhost:1234/api',
    metaschema_uri => 'https://spec.openapis.org/oas/3.1/schema',
    evaluator => my $js = JSON::Schema::Modern->new,
    schema => {
      %$preamble,
      components => {
        parameters => {
          foo => { '$ref' => '#/components/parameters/bar' },
          bar => { '$ref' => '#/components/parameters/foo' },
          baz => { name => 'baz', in => 'query', schema => {} },
          blip => { '$ref' => '#/components/schemas/bar/properties/foo' },
        },
        schemas => {
          foo => { '$ref' => 'http://localhost:5678/api#/properties/foo' },
          bar => {
            '$id' => 'http://localhost:5678/api',
            type => 'object',
            properties => { foo => { type => 'string' } },
          },
        },
      },
      paths => {
        '/foo' => {
          post => {
            parameters => [
              { '$ref' => '#/i_do_not_exist' },
              { '$ref' => '#/components/parameters/foo' },
              { '$ref' => '#/components/parameters/baz' },
              { '$ref' => '#/components/parameters/blip' },
              { '$ref' => 'http://far_far_away/api2#/components/schemas/alpha' },
            ],
          },
        },
      },
    },
  );

  is($doc->errors, 0, 'no errors during traversal');

  my $openapi = OpenAPI::Modern->new(
    openapi_document => $doc,
  );

  my $doc2 = JSON::Schema::Modern::Document::OpenAPI->new(
    canonical_uri => 'http://far_far_away/api2',
    metaschema_uri => 'https://spec.openapis.org/oas/3.1/schema',
    evaluator => $js,
    schema => {
      %$preamble,
      components => {
        schemas => {
          alpha => { type => 'integer' },
        },
      },
    },
  );

  is($doc2->errors, 0, 'no errors during traversal');
  $openapi->evaluator->add_schema($doc2);

  like(
    exception { $openapi->recursive_get('#/paths/~1foo/post/parameters/0') },
    qr'^unable to find resource http://localhost:1234/api#/i_do_not_exist',
    'failure to resolve $ref',
  );

  like(
    exception { $openapi->recursive_get('#/paths/~1foo/post/parameters/1') },
    qr{^maximum evaluation depth exceeded},
    'endless loop',
  );

  cmp_deeply(
    [ $openapi->recursive_get('#/paths/~1foo/post/parameters/2') ],
    [ { name => 'baz', in => 'query', schema => {} }, str('http://localhost:1234/api#/components/parameters/baz') ],
    'successful get through a $ref',
  );

  cmp_deeply(
    [ $openapi->recursive_get('#/paths/~1foo/post/parameters/3') ],
    [ { type => 'string' }, str('http://localhost:5678/api#/properties/foo') ],
    'successful get through multiple $refs, with a change of base uri',
  );

  cmp_deeply(
    [ $openapi->recursive_get('#/paths/~1foo/post/parameters/4') ],
    [ { type => 'integer' }, str('http://far_far_away/api2#/components/schemas/alpha') ],
    'successful get through multiple $refs, with a change of document',
  );
};

done_testing;
