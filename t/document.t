use strict;
use warnings;
use 5.016;
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Modern;
use JSON::Schema::Modern::Document::OpenAPI;

my $valid_schema = {
  openapi => '3.1.0',
  info => {
    title => 'my title',
    version => '1.2.3',
  },
};

subtest 'basic construction' => sub {
  my $doc = JSON::Schema::Modern::Document::OpenAPI->new(
    canonical_uri => 'http://localhost:1234/api',
    evaluator => my $js = JSON::Schema::Modern->new,
    schema => $valid_schema,
  );

  cmp_deeply(
    { $doc->resource_index },
    {
      'http://localhost:1234/api' => {
        path => '',
        canonical_uri => str('http://localhost:1234/api'),
        specification_version => 'draft2020-12',
        vocabularies => ignore, # TODO, after we parse /jsonSchemaDialect
      },
    },
    'the document itself is recorded as a resource',
  );
};

subtest 'top level document fields' => sub {
  my $doc = JSON::Schema::Modern::Document::OpenAPI->new(
    canonical_uri => 'http://localhost:1234/api',
    evaluator => my $js = JSON::Schema::Modern->new,
    schema => {},
  );
  cmp_deeply(
    [ map $_->TO_JSON, $doc->errors ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/openapi',
        absoluteKeywordLocation => 'http://localhost:1234/api#/openapi',
        error => 'openapi keyword is required',
      },
    ],
    'missing openapi',
  );

  $doc = JSON::Schema::Modern::Document::OpenAPI->new(
    canonical_uri => 'http://localhost:1234/api',
    evaluator => $js,
    schema => {
      openapi => '2.1.3',
      info => {
        title => undef,
        version => undef,
      },
    },
  );
  cmp_deeply(
    [ map $_->TO_JSON, $doc->errors ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/openapi',
        absoluteKeywordLocation => 'http://localhost:1234/api#/openapi',
        error => 'unrecognized openapi version 2.1.3',
      },
      {
        instanceLocation => '',
        keywordLocation => '/info/title',
        absoluteKeywordLocation => 'http://localhost:1234/api#/info/title',
        error => 'title value is not a string',
      },
      {
        instanceLocation => '',
        keywordLocation => '/info/version',
        absoluteKeywordLocation => 'http://localhost:1234/api#/info/version',
        error => 'version value is not a string',
      },
    ],
    'many invalid properties',
  );
};

done_testing;
