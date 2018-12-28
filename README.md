# NAME

SQL::Translator::Parser::OpenAPI - convert OpenAPI schema to SQL::Translator schema

# PROJECT STATUS

| OS      |  Build status |
|:-------:|--------------:|
| Linux   | [![Build Status](https://travis-ci.org/mohawk2/SQL-Translator-Parser-OpenAPI.svg?branch=master)](https://travis-ci.org/mohawk2/SQL-Translator-Parser-OpenAPI) |

[![CPAN version](https://badge.fury.io/pl/SQL-Translator-Parser-OpenAPI.svg)](https://metacpan.org/pod/SQL::Translator::Parser::OpenAPI) [![Coverage Status](https://coveralls.io/repos/github/mohawk2/SQL-Translator-Parser-OpenAPI/badge.svg?branch=master)](https://coveralls.io/github/mohawk2/SQL-Translator-Parser-OpenAPI?branch=master)

# SYNOPSIS

    use SQL::Translator;
    use SQL::Translator::Parser::OpenAPI;

    my $translator = SQL::Translator->new;
    $translator->parser("OpenAPI");
    $translator->producer("YAML");
    $translator->translate($file);

    # or...
    $ sqlt -f OpenAPI -t MySQL <my-openapi.json >my-mysqlschema.sql

    # or, applying an overlay:
    $ perl -MHash::Merge=merge -Mojo \
      -e 'print j merge map j(f($_)->slurp), @ARGV' \
        t/06-corpus.json t/06-corpus.json.overlay |
      sqlt -f OpenAPI -t MySQL >my-mysqlschema.sql

# DESCRIPTION

This module implements a [SQL::Translator::Parser](https://metacpan.org/pod/SQL::Translator::Parser) to convert
a [JSON::Validator::OpenAPI::Mojolicious](https://metacpan.org/pod/JSON::Validator::OpenAPI::Mojolicious) specification to a [SQL::Translator::Schema](https://metacpan.org/pod/SQL::Translator::Schema).

It uses, from the given API spec, the given "definitions" to generate
tables in an RDBMS with suitable columns and types.

To try to make the data model represent the "real" data, it applies heuristics:

- to remove object definitions considered non-fundamental; see
["definitions\_non\_fundamental" in Yancy::Util](https://metacpan.org/pod/Yancy::Util#definitions_non_fundamental).
- for definitions that have `allOf`, either merge them together if there
is a `discriminator`, or absorb properties from referred definitions
- creates object definitions for any properties that are an object
- creates object definitions for any properties that are an array of simple
OpenAPI types (e.g. `string`)
- creates object definitions for any objects that are
`additionalProperties` (i.e. freeform key/value pairs), that are
key/value rows
- absorbs any definitions that are in fact not objects, into the referring
property
- injects foreign-key relationships for array-of-object properties, and
creates many-to-many tables for any two-way array relationships

# ARGUMENTS

## snake\_case

If true, will create table names that are not the definition names, but
instead the pluralised snake\_case version, in line with SQL convention. By
default, the tables will be named after simply the definitions.

# PACKAGE FUNCTIONS

## parse

Standard as per [SQL::Translator::Parser](https://metacpan.org/pod/SQL::Translator::Parser). The input $data is a scalar
that can be understood as a [JSON::Validator
specification](https://metacpan.org/pod/JSON::Validator#schema).

# OPENAPI SPEC EXTENSIONS

## `x-id-field`

Under `/definitions/$defname`, a key of `x-id-field` will name a
field within the `properties` to be the unique ID for that entity.
If it is not given, the `id` field will be used if in the spec, or
created if not.

This will form the ostensible "key" for the generated table. If the
key used here is an integer type, it will also be the primary key,
being a suitable "natural" key. If not, then a "surrogate" key (with a
generated name starting with `_relational_id`) will be added as the primary
key. If a surrogate key is made, the natural key will be given a unique
constraint and index, making it still suitable for lookups. Foreign key
relations will however be constructed using the relational primary key,
be that surrogate if created, or natural.

## `x-view-of`

Under `/definitions/$defname`, a key of `x-view-of` will name another
definition (NB: not a full JSON pointer). That will make `$defname`
not be created as a table. The handling of creating the "view" of the
relevant table is left to the CRUD implementation. This gives it scope
to use things like the current requesting user, or web parameters,
which otherwise would require a parameterised view. These are not widely
available.

## `x-artifact`

Under `/definitions/$defname/properties/$propname`, a key of
`x-artifact` with a true value will indicate this is not to be stored,
and will not cause a column to be created. The value will instead be
derived by other means. The value of this key may become the definition
of that derivation.

## `x-input-only`

Under `/definitions/$defname/properties/$propname`, a key of
`x-input-only` with a true value will indicate this is not to be stored,
and will not cause a column to be created. This may end up being merged
with `x-artifact`.

# DEBUGGING

To debug, set environment variable `SQLTP_OPENAPI_DEBUG` to a true value.

# AUTHOR

Ed J, `<etj at cpan.org>`

# LICENSE

Copyright (C) Ed J

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# SEE ALSO

[SQL::Translator](https://metacpan.org/pod/SQL::Translator).

[SQL::Translator::Parser](https://metacpan.org/pod/SQL::Translator::Parser).

[JSON::Validator::OpenAPI::Mojolicious](https://metacpan.org/pod/JSON::Validator::OpenAPI::Mojolicious).
