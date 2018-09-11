use strict;
use warnings;
use Test::More 0.98;

use_ok 'SQL::Translator::Parser::OpenAPI', 'defs2mask';

# properties:
my $defs = {
  d1 => {
    properties => {
      p1 => 'string',
      p2 => 'string',
    },
  },
  d2 => {
    properties => {
      p2 => 'string',
      p3 => 'string',
    },
  },
};
my $mask = SQL::Translator::Parser::OpenAPI::defs2mask($defs);
# all prop names, sorted: qw(p1 p2 p3)
# $mask:
my $expected = {
  d1 => (1 << 0) | (1 << 1),
  d2 => (1 << 1) | (1 << 2),
};
is_deeply $mask, $expected, 'basic mask check';

done_testing;
