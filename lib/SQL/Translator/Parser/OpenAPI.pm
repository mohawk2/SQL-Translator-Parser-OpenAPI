package SQL::Translator::Parser::OpenAPI;
use 5.008001;
use strict;
use warnings;
use JSON::Validator::OpenAPI;

our $VERSION = "0.02";
use constant DEBUG => $ENV{SQLTP_OPENAPI_DEBUG};
use String::CamelCase qw(camelize decamelize wordsplit);
use Lingua::EN::Inflect::Number qw(to_PL to_S);
use SQL::Translator::Schema::Constants;
use Math::BigInt;

my %TYPE2SQL = (
  integer => 'int',
  int32 => 'int',
  int64 => 'bigint',
  float => 'float',
  number => 'double',
  double => 'double',
  string => 'varchar',
  byte => 'byte',
  binary => 'binary',
  boolean => 'bit',
  date => 'date',
  'date-time' => 'datetime',
  password => 'varchar',
);

# from GraphQL::Debug
sub _debug {
  my $func = shift;
  require Data::Dumper;
  require Test::More;
  local ($Data::Dumper::Sortkeys, $Data::Dumper::Indent, $Data::Dumper::Terse);
  $Data::Dumper::Sortkeys = $Data::Dumper::Indent = $Data::Dumper::Terse = 1;
  Test::More::diag("$func: ", Data::Dumper::Dumper([ @_ ]));
}

# heuristic 1: strip out single-item objects
sub _strip_thin {
  my ($defs) = @_;
  my @thin = grep { keys(%{ $defs->{$_}{properties} }) == 1 } keys %$defs;
  if (DEBUG) {
    _debug("OpenAPI($_) thin, ignoring", $defs->{$_}{properties})
      for sort @thin;
  }
  @thin;
}

# heuristic 2: find objects with same propnames, drop those with longer names
sub _strip_dup {
  my ($defs, $def2mask, $reffed) = @_;
  my %sig2names;
  push @{ $sig2names{$def2mask->{$_}} }, $_ for keys %$def2mask;
  DEBUG and _debug("OpenAPI sig2names", \%sig2names);
  my @nondups = grep @{ $sig2names{$_} } == 1, keys %sig2names;
  delete @sig2names{@nondups};
  my @dups;
  for my $sig (keys %sig2names) {
    next if grep $reffed->{$_}, @{ $sig2names{$sig} };
    my @names = sort { (length $a <=> length $b) } @{ $sig2names{$sig} };
    DEBUG and _debug("OpenAPI dup($sig)", \@names);
    shift @names; # keep the first i.e. shortest
    push @dups, @names;
  }
  @dups;
}

# sorted list of all propnames
sub _get_all_propnames {
  my ($defs) = @_;
  my %allprops;
  for my $defname (keys %$defs) {
    $allprops{$_} = 1 for keys %{ $defs->{$defname}{properties} };
  }
  [ sort keys %allprops ];
}

sub defs2mask {
  my ($defs) = @_;
  my $allpropnames = _get_all_propnames($defs);
  my $count = 0;
  my %prop2count;
  for my $propname (@$allpropnames) {
    $prop2count{$propname} = $count;
    $count++;
  }
  my %def2mask;
  for my $defname (keys %$defs) {
    $def2mask{$defname} ||= Math::BigInt->new(0);
    $def2mask{$defname} |= (Math::BigInt->new(1) << $prop2count{$_})
      for keys %{ $defs->{$defname}{properties} };
  }
  \%def2mask;
}

# heuristic 3: find objects with set of propnames that is subset of
#   another object's propnames
sub _strip_subset {
  my ($defs, $def2mask, $reffed) = @_;
  my %subsets;
  for my $defname (keys %$defs) {
    DEBUG and _debug("_strip_subset $defname maybe", $reffed);
    next if $reffed->{$defname};
    my $thismask = $def2mask->{$defname};
    for my $supersetname (grep $_ ne $defname, keys %$defs) {
      my $supermask = $def2mask->{$supersetname};
      next unless ($thismask & $supermask) == $thismask;
      DEBUG and _debug("mask $defname subset $supersetname");
      $subsets{$defname} = 1;
    }
  }
  keys %subsets;
}

sub _prop2sqltype {
  my ($prop) = @_;
  my $format_type = $prop->{format} || $prop->{type};
  my $lookup = $TYPE2SQL{$format_type || ''};
  DEBUG and _debug("_prop2sqltype($format_type)($lookup)", $prop);
  my %retval = (data_type => $lookup);
  if (@{$prop->{enum} || []}) {
    $retval{data_type} = 'enum';
    $retval{extra} = { list => [ @{$prop->{enum}} ] };
  }
  DEBUG and _debug("_prop2sqltype(end)", \%retval);
  \%retval;
}

sub _make_not_null {
  my ($table, $field) = @_;
  $field->is_nullable(0);
  $table->add_constraint(type => $_, fields => $field)
    for (NOT_NULL);
}

sub _make_pk {
  my ($table, $field) = @_;
  $field->is_primary_key(1);
  $field->is_auto_increment(1);
  $table->add_constraint(type => $_, fields => $field)
    for (PRIMARY_KEY);
  my $index = $table->add_index(name => "pk_${field}", fields => [ $field ]);
  _make_not_null($table, $field);
}

sub _def2tablename {
  to_PL decamelize $_[0];
}

sub _ref2def {
  my ($ref) = @_;
  $ref =~ s:^#/definitions/:: or return;
  $ref;
}

sub _make_fk {
  my ($table, $field, $foreign_tablename, $foreign_id) = @_;
  $table->add_constraint(
    type => FOREIGN_KEY, fields => $field,
    reference_table => $foreign_tablename,
    reference_fields => $foreign_id,
  );
}

sub _fk_hookup {
  my ($schema, $fromtable, $fromkey, $totable, $tokey, $required) = @_;
  DEBUG and _debug("_fk_hookup($fromkey)(ref)($totable)");
  my $from_obj = $schema->get_table($fromtable);
  my $to_obj = $schema->get_table($totable);
  my $tokey_obj = $to_obj->get_field($tokey);
  my $field = $from_obj->add_field(
    name => $fromkey, data_type => $tokey_obj->data_type,
  );
  _make_fk($from_obj, $field, $totable, $tokey);
  _make_not_null($from_obj, $field) if $required;
  $field;
}

sub _def2table {
  my ($name, $def, $schema) = @_;
  my $props = $def->{properties};
  my $tname = _def2tablename($name);
  DEBUG and _debug("_def2table($name)($tname)", $props);
  my $table = $schema->add_table(
    name => $tname, comments => $def->{description},
  );
  if (!$props->{id}) {
    # we need a relational id
    $props->{id} = { type => 'integer' };
  }
  my %prop2required = map { ($_ => 1) } @{ $def->{required} || [] };
  my (@fixups);
  for my $propname (sort keys %$props) {
    my $field;
    my $thisprop = $props->{$propname};
    DEBUG and _debug("_def2table($propname)");
    if (my $ref = $thisprop->{'$ref'}) {
      push @fixups, {
        to => _def2tablename(_ref2def($ref)), from => $tname,
        tokey => 'id', fromkey => $propname . '_id',
        required => $prop2required{$propname},
      };
    } elsif (($thisprop->{type} // '') eq 'array') {
      if (my $ref = $thisprop->{items}{'$ref'}) {
        push @fixups, {
          to => $tname, from => _ref2def(_def2tablename($ref)),
          tokey => 'id', fromkey => to_S(${tname}) . "_id",
          required => 1,
        };
      }
      DEBUG and _debug("_def2table(array)($propname)", \@fixups);
    } else {
      my $sqltype = _prop2sqltype($thisprop);
      $field = $table->add_field(
        name => $propname, %$sqltype, comments => $thisprop->{description},
      );
      if ($propname eq 'id') {
        _make_pk($table, $field);
      }
    }
    if ($field and $prop2required{$propname} and $propname ne 'id') {
      _make_not_null($table, $field);
    }
  }
  ($table, \@fixups);
}

# mutates $def
sub _merge_one {
  my ($def, $from, $ignore_required) = @_;
  DEBUG and _debug('OpenAPI._merge_one', $def, $from);
  push @{ $def->{required} }, @{ $from->{required} || [] } if !$ignore_required;
  $def->{properties} = { %{$def->{properties} || {}}, %{$from->{properties}} };
  $def->{type} = $from->{type} if $from->{type};
}

sub _merge_allOf {
  my ($defs) = @_;
  DEBUG and _debug('OpenAPI._merge_allOf', $defs);
  my %def2discrim = map {
    ($_ => 1)
  } grep $defs->{$_}{discriminator}, keys %$defs;
  my %def2referrers;
  for my $defname (sort keys %$defs) {
    my $thisdef = $defs->{$defname};
    next if !exists $thisdef->{allOf};
    for my $partial (@{ $thisdef->{allOf} }) {
      next if !(my $ref = $partial->{'$ref'});
      push @{ $def2referrers{_ref2def($ref)} }, $defname;
    }
  }
  DEBUG and _debug('OpenAPI._merge_allOf(def2referrers)', \%def2referrers);
  my %newdefs;
  my %def2ignore;
  for my $defname (sort grep $def2discrim{$_}, keys %def2referrers) {
    # assimilate instead of be assimilated by
    $def2ignore{$defname} = 1;
    my $thisdef = $defs->{$defname};
    my %new = %$thisdef;
    for my $assimilee (@{ $def2referrers{$defname} }) {
      $def2ignore{$assimilee} = 1;
      my $assimileedef = $defs->{$assimilee};
      my @all = @{ $assimileedef->{allOf} };
      for my $partial (@all) {
        next if exists $partial->{'$ref'};
        _merge_one(\%new, $partial, 1);
      }
    }
    $newdefs{$defname} = \%new;
  }
  for my $defname (sort grep !$def2ignore{$_}, keys %$defs) {
    my $thisdef = $defs->{$defname};
    my %new = %$thisdef;
    if (exists $thisdef->{allOf}) {
      my @all = @{ delete $thisdef->{allOf} };
      for my $partial (@all) {
        if (exists $partial->{'$ref'}) {
          _merge_one(\%new, $defs->{ _ref2def($partial->{'$ref'}) }, 0);
        } else {
          _merge_one(\%new, $partial, 0);
        }
      }
    }
    $newdefs{$defname} = \%new;
  }
  DEBUG and _debug('OpenAPI._merge_allOf(end)', \%newdefs);
  \%newdefs;
}

sub _find_referenced {
  my ($defs) = @_;
  DEBUG and _debug('OpenAPI._find_referenced', $defs);
  my %reffed;
  for my $defname (sort keys %$defs) {
    my $theseprops = $defs->{$defname}{properties} || {};
    for my $propname (keys %$theseprops) {
      if (my $ref = $theseprops->{$propname}{'$ref'}
        || ($theseprops->{$propname}{items} && $theseprops->{$propname}{items}{'$ref'})
      ) {
        $reffed{ _ref2def($ref) } = 1;
      }
    }
  }
  DEBUG and _debug('OpenAPI._find_referenced(end)', \%reffed);
  \%reffed;
}

sub _extract_objects {
  my ($defs) = @_;
  DEBUG and _debug('OpenAPI._extract_objects', $defs);
  my %newdefs = %$defs;
  for my $defname (sort keys %$defs) {
    my $theseprops = $defs->{$defname}{properties} || {};
    for my $propname (keys %$theseprops) {
      my $thisprop = $theseprops->{$propname};
      next if $thisprop->{'$ref'}
        or $thisprop->{items} && $thisprop->{items}{'$ref'};
      my $ref;
      if (($thisprop->{type} // '') eq 'object') {
        $ref = $thisprop;
      } elsif (
        $thisprop->{items} && ($thisprop->{items}{type} // '') eq 'object'
      ) {
        $ref = $thisprop->{items};
      } else {
        next;
      }
      my $newtype = join '', map camelize($_), $defname, $propname;
      $newdefs{$newtype} = { %$ref };
      %$ref = ('$ref' => "#/definitions/$newtype");
    }
  }
  DEBUG and _debug('OpenAPI._extract_objects(end)', \%newdefs);
  \%newdefs;
}

sub _extract_array_simple {
  my ($defs) = @_;
  DEBUG and _debug('OpenAPI._extract_array_simple', $defs);
  my %newdefs = %$defs;
  for my $defname (sort keys %$defs) {
    my $theseprops = $defs->{$defname}{properties} || {};
    for my $propname (keys %$theseprops) {
      my $thisprop = $theseprops->{$propname};
      next if $thisprop->{'$ref'};
      next unless
        $thisprop->{items} && ($thisprop->{items}{type} // '') ne 'object';
      my $ref = $thisprop->{items};
      my $newtype = join '', map camelize($_), $defname, $propname;
      $newdefs{$newtype} = {
        type => 'object',
        properties => {
          value => { %$ref }
        },
        required => [ 'value' ],
      };
      %$ref = ('$ref' => "#/definitions/$newtype");
    }
  }
  DEBUG and _debug('OpenAPI._extract_array_simple(end)', \%newdefs);
  \%newdefs;
}

sub _fixup_addProps {
  my ($defs) = @_;
  DEBUG and _debug('OpenAPI._fixup_addProps', $defs);
  my %def2aP = map {$_,1} grep $defs->{$_}{additionalProperties}, keys %$defs;
  DEBUG and _debug("OpenAPI._fixup_addProps(d2aP)", \%def2aP);
  for my $defname (sort keys %$defs) {
    my $theseprops = $defs->{$defname}{properties} || {};
    DEBUG and _debug("OpenAPI._fixup_addProps(arrayfix)($defname)", $theseprops);
    for my $propname (keys %$theseprops) {
      my $thisprop = $theseprops->{$propname};
      DEBUG and _debug("OpenAPI._fixup_addProps(p)($propname)", $thisprop);
      next unless $thisprop->{'$ref'}
        or $thisprop->{items} && $thisprop->{items}{'$ref'};
      DEBUG and _debug("OpenAPI._fixup_addProps(p)($propname)(y)");
      my $ref;
      if ($thisprop->{'$ref'}) {
        $ref = $thisprop;
      } elsif ($thisprop->{items} && $thisprop->{items}{'$ref'}) {
        $ref = $thisprop->{items};
      } else {
        next;
      }
      my $refname = $ref->{'$ref'};
      DEBUG and _debug("OpenAPI._fixup_addProps(p)($propname)(y2)($refname)", $ref);
      next if !$def2aP{_ref2def($refname)};
      %$ref = (type => 'array', items => { '$ref' => $refname });
      DEBUG and _debug("OpenAPI._fixup_addProps(p)($propname)(y3)", $ref);
    }
  }
  my %newdefs = %$defs;
  for my $defname (keys %def2aP) {
    my %kv = (type => 'object', properties => {
      key => { type => 'string' },
      value => { type => $defs->{$defname}{additionalProperties}{type} },
    });
    $newdefs{$defname} = \%kv;
  }
  DEBUG and _debug('OpenAPI._fixup_addProps(end)', \%newdefs);
  \%newdefs;
}

sub parse {
  my ($tr, $data) = @_;
  my $openapi_schema = JSON::Validator::OpenAPI->new->schema($data)->schema;
  my %defs = %{ $openapi_schema->get("/definitions") };
  DEBUG and _debug('OpenAPI.definitions', \%defs);
  my $schema = $tr->schema;
  my @thin = _strip_thin(\%defs);
  DEBUG and _debug("thin ret", \@thin);
  delete @defs{@thin};
  %defs = %{ _merge_allOf(\%defs) };
  my $def2mask = defs2mask(\%defs);
  my $reffed = _find_referenced(\%defs);
  my @dup = _strip_dup(\%defs, $def2mask, $reffed);
  DEBUG and _debug("dup ret", \@dup);
  delete @defs{@dup};
  my @subset = _strip_subset(\%defs, $def2mask, $reffed);
  DEBUG and _debug("subset ret", [ sort @subset ]);
  delete @defs{@subset};
  DEBUG and _debug("remaining", [ sort keys %defs ]);
  %defs = %{ _extract_objects(\%defs) };
  DEBUG and _debug("after _extract_objects", [ sort keys %defs ]);
  %defs = %{ _extract_array_simple(\%defs) };
  DEBUG and _debug("after _extract_array_simple", [ sort keys %defs ]);
  my (@fixups);
  %defs = %{ _fixup_addProps(\%defs) };
  for my $name (sort keys %defs) {
    my ($table, $thesefixups) = _def2table($name, $defs{$name}, $schema);
    push @fixups, @$thesefixups;
    DEBUG and _debug("table", $table, $thesefixups);
  }
  DEBUG and _debug("tables to do", \@fixups);
  for my $fixup (@fixups) {
    _fk_hookup($schema, @{$fixup}{qw(from fromkey to tokey required)});
  }
  1;
}

=encoding utf-8

=head1 NAME

SQL::Translator::Parser::OpenAPI - convert OpenAPI schema to SQL::Translator schema

=begin markdown

# PROJECT STATUS

| OS      |  Build status |
|:-------:|--------------:|
| Linux   | [![Build Status](https://travis-ci.org/mohawk2/SQL-Translator-Parser-OpenAPI.svg?branch=master)](https://travis-ci.org/mohawk2/SQL-Translator-Parser-OpenAPI) |

[![CPAN version](https://badge.fury.io/pl/SQL-Translator-Parser-OpenAPI.svg)](https://metacpan.org/pod/SQL::Translator::Parser::OpenAPI) [![Coverage Status](https://coveralls.io/repos/github/mohawk2/SQL-Translator-Parser-OpenAPI/badge.svg?branch=master)](https://coveralls.io/github/mohawk2/SQL-Translator-Parser-OpenAPI?branch=master)

=end markdown

=head1 SYNOPSIS

  use SQL::Translator;
  use SQL::Translator::Parser::OpenAPI;

  my $translator = SQL::Translator->new;
  $translator->parser("OpenAPI");
  $translator->producer("YAML");
  $translator->translate($file);

  # or...
  $ sqlt -f OpenAPI -t MySQL <my-openapi.json >my-mysqlschema.sql

=head1 DESCRIPTION

This module implements a L<SQL::Translator::Parser> to convert
a L<JSON::Validator::OpenAPI> specification to a L<SQL::Translator::Schema>.

It uses, from the given API spec, the given "definitions" to generate
tables in an RDBMS with suitable columns and types.

To try to make the data model represent the "real" data, it applies heuristics:

=over

=item *

to remove object definitions that only have one property

=item *

to find object definitions that have all the same properties as another,
and remove all but the shortest-named one

=item *

to remove object definitions whose properties are a strict subset
of another

=back

=head1 ARGUMENTS

None at present.

=head1 PACKAGE FUNCTIONS

=head2 parse

Standard as per L<SQL::Translator::Parser>. The input $data is a scalar
that can be understood as a L<JSON::Validator
specification|JSON::Validator/schema>.

=head2 defs2mask

Given a hashref that is a JSON pointer to an OpenAPI spec's
C</definitions>, returns a hashref that maps each definition name to a
bitmask. The bitmask is set from each property name in that definition,
according to its order in the complete sorted list of all property names
in the definitions. Not exported. E.g.

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
  {
    d1 => (1 << 0) | (1 << 1),
    d2 => (1 << 1) | (1 << 2),
  }

=head1 DEBUGGING

To debug, set environment variable C<SQLTP_OPENAPI_DEBUG> to a true value.

=head1 AUTHOR

Ed J, C<< <etj at cpan.org> >>

=head1 LICENSE

Copyright (C) Ed J

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<SQL::Translator>.

L<SQL::Translator::Parser>.

L<JSON::Validator::OpenAPI>.

=cut

1;
