use strict;
use warnings;
# no package, so things defined here appear in the namespace of the parent.
use 5.020;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Safe::Isa;
use HTTP::Request;
use HTTP::Response;
use HTTP::Status ();
use Mojo::Message::Request;
use Mojo::Message::Response;

# type can be
# 'lwp': classes of type URI, HTTP::Headers, HTTP::Request, HTTP::Response
# 'mojo': classes of type Mojo::URL, Mojo::Headers, Mojo::Message::Request, Mojo::Message::Response
our @TYPES = qw(lwp mojo);
our $TYPE;

sub request ($method, $uri_string, $headers = [], $body_content = undef) {
  die '$TYPE is not set' if not defined $TYPE;

  my $req;
  if ($TYPE eq 'lwp') {
    my $uri = URI->new($uri_string);
    my $host = $uri->$_call_if_can('host');
    $uri->scheme(undef);
    $uri->$_call_if_can(host => undef);
    $req = HTTP::Request->new($method => $uri, [ @$headers, $host ? ( Host => $host ) : () ], $body_content);
  }
  elsif ($TYPE eq 'mojo') {
    my $uri = Mojo::URL->new($uri_string);
    my $host = $uri->host;
    $uri->scheme(undef);
    $uri->host(undef);
    $req = Mojo::Message::Request->new(method => $method, url => Mojo::URL->new($uri_string));
    while (my ($name, $value) = splice(@$headers, 0, 2)) {
      $req->headers->header($name, $value);
    }
    $req->headers->header('Host', $host) if $host;
    $req->body($body_content) if defined $body_content;
  }
  else {
    die '$TYPE '.$TYPE.' not supported';
  }

  return $req;
}

sub response ($code, $headers = [], $body_content = undef) {
  die '$TYPE is not set' if not defined $TYPE;

  my $res;
  if ($TYPE eq 'lwp') {
    $res = HTTP::Response->new($code, HTTP::Status::status_message($code), $headers, $body_content);
  }
  elsif ($TYPE eq 'mojo') {
    $res = Mojo::Message::Response->new(code => $code);
    $res->message($res->default_message);
    while (my ($name, $value) = splice(@$headers, 0, 2)) {
      $res->headers->header($name, $value);
    }
    $res->body($body_content) if defined $body_content;
  }
  else {
    die '$TYPE '.$TYPE.' not supported';
  }

  return $res;
}

sub uri ($uri_string, @path_parts) {
  die '$TYPE is not set' if not defined $TYPE;

  my $uri;
  if ($TYPE eq 'lwp') {
    $uri = URI->new($uri_string);
    $uri->path_segments(@path_parts) if @path_parts;
  }
  elsif ($TYPE eq 'mojo') {
    $uri = Mojo::URL->new($uri_string);
    $uri->path->parts(\@path_parts) if @path_parts;
  }
  else {
    die '$TYPE '.$TYPE.' not supported';
  }

  return $uri;
}

1;
