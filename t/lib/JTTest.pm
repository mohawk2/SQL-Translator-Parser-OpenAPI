package JTTest;

my @IMPORT;
BEGIN {
@IMPORT = qw(
  strict
  warnings
  Test::More
  Test::Snapshot
  SQL::Translator
  SQL::Translator::Parser::OpenAPI
);
do { eval "use $_; 1" or die $@ } for @IMPORT;
}

use parent 'Exporter';
use Import::Into;

# nothing yet
our @EXPORT = qw(
  run_test
);

sub import {
  my $class = shift;
  my $target = caller;
  $class->export_to_level(1);
  $_->import::into(1) for @IMPORT;
}

sub run_test {
  (my $file = $0) =~ s#schema\.t$#corpus.json#;
  $file =~ s#json$#yml# if !-f $file;
  die "$file: $!" if !-f $file;

  require JSON::Validator::OpenAPI;
  my $openapi_schema = JSON::Validator::OpenAPI->new->schema($file)->schema->data;

  my $translator = SQL::Translator->new;
  $translator->parser("OpenAPI");
  $translator->producer("MySQL");

  my $got = $translator->translate(data => $openapi_schema);
  if ($got) {
    my @lines = split /\n/, $got;
    splice @lines, 0, 4; # zap opening blurb to dodge false negs
    $got = join "\n", @lines;
  } else {
    diag $translator->error;
  }
  is_deeply_snapshot $got, 'schema';
}

1;