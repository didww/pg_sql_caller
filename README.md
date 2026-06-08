# PgSqlCaller

[![Gem Version](https://img.shields.io/gem/v/pg_sql_caller.svg)](https://rubygems.org/gems/pg_sql_caller)
[![CI](https://github.com/didww/pg_sql_caller/actions/workflows/ci.yml/badge.svg)](https://github.com/didww/pg_sql_caller/actions/workflows/ci.yml)
[![CodeQL](https://github.com/didww/pg_sql_caller/actions/workflows/codeql.yml/badge.svg)](https://github.com/didww/pg_sql_caller/actions/workflows/codeql.yml)

A small, focused wrapper for running **raw SQL against PostgreSQL through ActiveRecord**.

It gives you a clean API for the things ActiveRecord's query builder makes awkward — `SELECT`s that return a single scalar, a single column, raw rows, `EXPLAIN ANALYZE`, sequence/table introspection, PostgreSQL `NOTICE` capture, and efficient set-based bulk updates — while keeping every value **bound and sanitized** by ActiveRecord so your statements stay injection-safe.

```ruby
class Sql < PgSqlCaller::Base
  model_class 'ApplicationRecord'
end

Sql.select_value('SELECT count(*) FROM users WHERE active = ?', true) # => 42
Sql.select_values('SELECT id FROM users WHERE name = ?', 'John Doe')  # => [1, 2, 3]
Sql.transaction { Sql.execute('DELETE FROM logs WHERE created_at < ?', 1.year.ago) }
```

## Table of contents

- [Why use this](#why-use-this)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration) — three ways to set it up
- [How `?` placeholders work](#how--placeholders-work)
- [API reference](#api-reference)
  - [Reading data](#reading-data)
  - [Serialized reads (Ruby type casting)](#serialized-reads-ruby-type-casting)
  - [Writing data](#writing-data)
  - [Transactions](#transactions)
  - [Database & table introspection](#database--table-introspection)
  - [Query plans](#query-plans)
  - [PostgreSQL NOTICE capture](#postgresql-notice-capture)
  - [Quoting & sanitizing helpers](#quoting--sanitizing-helpers)
  - [Extending with custom SQL methods](#extending-with-custom-sql-methods)
- [Bulk updates](#bulk-updates)
- [Security](#security)
- [Versioning & changelog](#versioning--changelog)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)

## Why use this

ActiveRecord already exposes low-level connection methods (`select_value`, `select_all`, `execute`, …), but reaching for them directly means writing `Model.connection.select_value(...)` everywhere, manually sanitizing bind values, and re-implementing the same small helpers in every project. `PgSqlCaller`:

- Wraps those connection methods behind a stable, documented API on a class **you** name.
- Binds `?` placeholders through ActiveRecord's sanitizer automatically — no manual quoting.
- Adds PostgreSQL-specific helpers (type-cast reads, sequence peeking, relation sizes, `EXPLAIN ANALYZE`, `NOTICE` capture).
- Provides a fast, injection-safe [bulk update](#bulk-updates) for partial updates of many existing rows in a single round-trip.

## Requirements

| Dependency    | Version            |
| ------------- | ------------------ |
| Ruby          | `>= 3.2.0`         |
| ActiveRecord  | `>= 7.1`           |
| ActiveSupport | `>= 7.1`           |
| Database      | PostgreSQL         |

Continuously tested against Rails **7.1, 7.2, 8.0, and 8.1** on Ruby **3.2–3.4**. PostgreSQL is required — the gem uses PostgreSQL-specific features (`pg_total_relation_size`, `unnest`, sequence introspection, the `pg` notice processor).

## Installation

Add to your application's `Gemfile`:

```ruby
gem 'pg_sql_caller'
```

Then run:

```sh
bundle install
```

Or install it directly:

```sh
gem install pg_sql_caller
```

## Configuration

A caller is always backed by **one ActiveRecord class**, whose connection runs every statement and whose column types are used to sanitize and cast values. Pick whichever of the three setups below fits your app.

### 1. Subclass `PgSqlCaller::Base` (recommended)

Declare the backing model once, then call SQL methods directly on your class. This is the most common setup and lets you have several callers (e.g. one per database) if needed.

```ruby
require 'pg_sql_caller'

class Sql < PgSqlCaller::Base
  model_class 'ApplicationRecord' # a String (constantized on first use) or the Class itself
end

Sql.select_values('SELECT id FROM users WHERE parent_name = ?', 'John Doe') # => [1, 2, 3]
```

`model_class` accepts either the class or its name as a `String`. Passing a `String` defers loading the constant until the first call, which avoids autoload-order problems at boot.

`PgSqlCaller::Base` is a `Singleton`: every class-level call is forwarded to the shared `.instance`, and **every** public instance method (including ones you add with [`define_sql_method`](#extending-with-custom-sql-methods)) is available as a class method.

### 2. Configure `PgSqlCaller::Base` directly

If you only need a single, global caller, configure the base class itself instead of subclassing:

```ruby
PgSqlCaller::Base.model_class 'ApplicationRecord'

PgSqlCaller::Base.select_values('SELECT id FROM users WHERE parent_name = ?', 'John Doe') # => [1, 2, 3]
```

### 3. Instantiate `PgSqlCaller::Model` per call

For one-off use, or when you want an ordinary object rather than a singleton, build a `Model` directly. This is also what [`BulkUpdate`](#bulk-updates) uses internally.

```ruby
sql = PgSqlCaller::Model.new(ApplicationRecord)
sql.select_value('SELECT count(*) FROM users') # => 42
```

> The class methods on `PgSqlCaller::Base` and the instance methods on `PgSqlCaller::Model` are the same API — the examples in the reference below use a `sql` instance, but `Sql.select_value(...)` works identically.

## How `?` placeholders work

Every reading and writing method takes a SQL string plus optional positional bindings. Each `?` in the SQL is replaced, **in order**, by a binding value that ActiveRecord quotes and escapes — values are never interpolated into the string yourself:

```ruby
sql.select_value('SELECT id FROM employees WHERE name = ?', "O'Brien")
# ActiveRecord turns this into:  SELECT id FROM employees WHERE name = 'O''Brien'
```

If you pass no bindings, the SQL is run verbatim. See [Security](#security) for the guarantees this provides.

## API reference

The examples use this schema:

```ruby
class Department < ApplicationRecord; end
class Employee   < ApplicationRecord  # columns: id, department_id, name, created_at, updated_at
  belongs_to :department
end
```

### Reading data

| Method                                  | Returns                                                              |
| --------------------------------------- | ------------------------------------------------------------------- |
| `select_value(sql, *bindings)`          | First column of the first row, or `nil` if no row matches           |
| `select_values(sql, *bindings)`         | First column of **every** row, as an `Array`                        |
| `select_row(sql, *bindings)`            | First row as an `Array` of column values, or `nil`                  |
| `select_rows(sql, *bindings)`           | Every row as an `Array` of column-value `Array`s                    |
| `select_all(sql, *bindings)`            | An `ActiveRecord::Result` of String-keyed row hashes                |

```ruby
sql.select_value('SELECT count(*) FROM employees')                       # => 2
sql.select_value('SELECT name FROM employees WHERE id = ?', -1)          # => nil

sql.select_values('SELECT name FROM employees WHERE department_id = ?', 5)
# => ["John", "Jane"]

sql.select_row('SELECT id, name FROM employees ORDER BY id')             # => [1, "John"]
sql.select_rows('SELECT id, name FROM employees')                        # => [[1, "John"], [2, "Jane"]]

result = sql.select_all('SELECT id, name FROM employees')
result                       # => #<ActiveRecord::Result ...>
result.to_a                  # => [{ "id" => 1, "name" => "John" }, { "id" => 2, "name" => "Jane" }]
```

> **Type casting note:** the non-serialized reads above return values as decoded by the PostgreSQL adapter — common scalar types (integers, booleans, floats, timestamps) come back as Ruby objects, but **array and other complex/custom column types arrive as raw strings** (e.g. `'{1,2,3}'`). Use the serialized variants below when you need those cast to Ruby types.

### Serialized reads (Ruby type casting)

The `*_serialized` variants run the same query, then cast each value back to its Ruby type using ActiveRecord's column types — handling arrays and custom attribute types that the raw adapter leaves as strings. `select_all_serialized` additionally keys each row by `Symbol`.

| Method                                    | Returns                                                       |
| ----------------------------------------- | ------------------------------------------------------------- |
| `select_value_serialized(sql, *bindings)` | First value of the first row, type-cast, or `nil`             |
| `select_values_serialized(sql, *bindings)`| Every row as an `Array` of type-cast values                   |
| `select_all_serialized(sql, *bindings)`   | Every row as a `Hash` with `Symbol` keys and type-cast values |

```ruby
# Raw read returns the PostgreSQL array literal as a String...
sql.select_value('SELECT ARRAY[1,2,3]::int[]')              # => "{1,2,3}"
# ...the serialized read casts it to a Ruby Array.
sql.select_value_serialized('SELECT ARRAY[1,2,3]::int[]')   # => [1, 2, 3]

sql.select_values_serialized('SELECT id, ARRAY[1,2]::int[] FROM employees')
# => [[1, [1, 2]]]

sql.select_all_serialized('SELECT id, created_at FROM employees')
# => [{ id: 1, created_at: 2026-06-08 12:00:00 +0000 }, ...]
```

### Writing data

| Method                     | Returns                                                       |
| -------------------------- | ------------------------------------------------------------- |
| `execute(sql, *bindings)`  | The raw `PG::Result` (use `#cmd_tuples` for affected rows)    |

`execute` is for `INSERT` / `UPDATE` / `DELETE` / DDL and any statement whose row data you don't need back.

```ruby
result = sql.execute('UPDATE employees SET name = ? WHERE id = ?', 'Renamed', 1)
result.cmd_tuples   # => 1  (number of rows affected)
```

For updating many existing rows efficiently, see [Bulk updates](#bulk-updates).

### Transactions

```ruby
sql.transaction do
  sql.execute('UPDATE accounts SET balance = balance - ? WHERE id = ?', 100, from_id)
  sql.execute('UPDATE accounts SET balance = balance + ? WHERE id = ?', 100, to_id)
end
```

- `transaction { ... }` — runs the block inside a database transaction, committing on success and rolling back if it raises. Returns the block's value. Raises `ArgumentError` if no block is given.
- `transaction_open?` — `true` when a transaction is currently open on the connection (including one opened on the model class itself, e.g. `ApplicationRecord.transaction { ... }`).

### Database & table introspection

| Method                          | Returns                                                                                   |
| ------------------------------- | ----------------------------------------------------------------------------------------- |
| `current_database`              | The connected database name (`SELECT current_database()`)                                 |
| `next_sequence_value(table)`    | The table's `<table>_id_seq` `last_value + 1`, read **without consuming** the sequence     |
| `table_full_size(table)`        | Total on-disk size in bytes including indexes & TOAST (`pg_total_relation_size`)          |
| `table_data_size(table)`        | Main data fork size in bytes only (`pg_relation_size`)                                    |

```ruby
sql.current_database                 # => "my_app_production"
sql.next_sequence_value('employees') # => 124
sql.table_full_size('employees')     # => 81920
sql.table_data_size('employees')     # => 8192
```

> `next_sequence_value` peeks at the sequence's current value; it does not allocate or advance it, so it is **not** safe to use as a way to reserve an id under concurrency.

### Query plans

```ruby
puts sql.explain_analyze('SELECT * FROM employees WHERE department_id = 5')
# QUERY_PLAN
# Seq Scan on employees  (cost=0.00..1.05 rows=1 width=...) (actual time=0.012..0.013 rows=1 loops=1)
#   Filter: (department_id = 5)
# Planning Time: 0.060 ms
# Execution Time: 0.030 ms
```

`explain_analyze(sql)` runs `EXPLAIN ANALYZE` (which **executes** the statement) and returns the plan as a single multi-line `String` under a `QUERY_PLAN` header.

### PostgreSQL NOTICE capture

Capture `NOTICE` output (e.g. from `RAISE NOTICE` inside a `DO` block or function) emitted while a block runs:

```ruby
sql.with_notice_processor(->(msg) { Rails.logger.info(msg) }) do
  sql.execute("DO $$ BEGIN RAISE NOTICE 'migrating row %', 42; END $$")
end
```

- `with_notice_processor(callback) { ... }` — invokes `callback` with each notice message (a chomped `String`) emitted during the block. Lowers `client_min_messages` to `notice` for the duration and restores the previous notice processor afterward. Returns the block's value.
- `with_min_messages(level) { ... }` — temporarily sets the connection's `client_min_messages` to `level` (`debug5`…`debug1`, `log`, `notice`, `warning`, `error`) for the block, restoring the previous value afterward. Returns the block's value.

### Quoting & sanitizing helpers

For the cases where you must build SQL fragments yourself, these expose ActiveRecord's quoting so you stay safe:

| Method                         | Purpose                                                                            |
| ------------------------------ | --------------------------------------------------------------------------------- |
| `quote_value(value)`           | Quote/escape a value as a SQL literal — `"O'Brien"` → `"'O''Brien'"`               |
| `quote_column_name(name)`      | Quote a column identifier — `"name"` → `'"name"'`                                  |
| `quote_table_name(name)`       | Quote a table identifier — `"employees"` → `'"employees"'`                         |
| `sanitize_sql_array(sql, *b)`  | Interpolate `?` placeholders and return the safe SQL `String` (no execution)       |
| `typecast_array(values, type:)`| Encode a Ruby `Array` into a PostgreSQL array literal for the given attribute type |

```ruby
sql.quote_value("O'Brien")                                 # => "'O''Brien'"
sql.quote_column_name('name')                              # => "\"name\""
sql.sanitize_sql_array('name = ? AND id = ?', "O'Brien", 5) # => "name = 'O''Brien' AND id = 5"
sql.typecast_array([1, 2, 3], type: :integer)              # => "{1,2,3}"
sql.typecast_array(['a', 'b,c'], type: :string)            # => "{a,\"b,c\"}"
```

Accessors `model_class` (the wrapped class) and `connection` (its adapter) are also public.

### Extending with custom SQL methods

`PgSqlCaller::Model` builds its core readers with the class macro `define_sql_method`, which wraps any connection method that takes a SQL string. Subclass `Model` (or `Base`) to expose additional connection methods with the same `?`-binding behavior:

```ruby
class Sql < PgSqlCaller::Base
  model_class 'ApplicationRecord'

  # Expose the adapter's #exec_query through the same binding/sanitizing path.
  define_sql_method :exec_query
end

Sql.exec_query('SELECT * FROM employees WHERE id = ?', 1)
```

Because `PgSqlCaller::Base` delegates missing class methods to its singleton instance, methods added this way are immediately callable at the class level.

## Bulk updates

`PgSqlCaller::BulkUpdate` performs a **partial update of many existing rows in a single statement and a single round-trip**, using `UPDATE ... FROM unnest(...)`. Each column is sent as one typed PostgreSQL array; `unnest` zips the arrays back into rows that are joined to the target table on a key.

```ruby
PgSqlCaller::BulkUpdate.call(Employee, [
  { id: 1, name: 'John', department_id: 10 },
  { id: 2, name: 'Jane', department_id: 20 }
])
# => 2   (number of rows affected)
```

### Matching on a composite key

By default rows are matched on `:id`. Pass `unique_by` to match on a different column, or an array of columns for a composite key:

```ruby
PgSqlCaller::BulkUpdate.call(Employee, attrs_list, unique_by: :employee_number)
PgSqlCaller::BulkUpdate.call(Employee, attrs_list, unique_by: %i[department_id name])
```

### Rules and behavior

- **Every row must include each `unique_by` column**, and all hashes must share the same set of keys.
- Only the columns you list are written; `unique_by` columns are used for matching, the rest are updated. Columns you omit (e.g. `created_at`) are left untouched.
- Rows that don't match an existing row are simply not updated — this **never inserts**.
- Returns the number of rows affected (`0` when `attrs_list` is empty — a no-op).
- Raises `ArgumentError` (before touching the database) if a row omits a `unique_by` column or names a column that doesn't exist on the model.

### Why not `upsert_all` or a loop of `update_all`?

- **vs. `upsert_all`:** PostgreSQL `NOT NULL`-checks the candidate `INSERT` tuple of `INSERT ... ON CONFLICT DO UPDATE` *before* conflict arbitration, so upsert rejects partial payloads that omit the table's other `NOT NULL` columns. This join only ever touches the listed columns of rows that already exist.
- **vs. N `update_all` calls in a transaction:** a transaction makes those writes atomic but doesn't batch them — it's still N statements, N round-trips, and N parse/plan cycles. `BulkUpdate` is one statement and one round-trip; round-trip latency dominates the N-call approach as the row count grows, so `BulkUpdate` stays roughly flat while the loop scales linearly.

> There's a benchmark demonstrating the speedup in `spec/pg_sql_caller/bulk_update_spec.rb`. Run it with:
> ```sh
> bundle exec rspec spec/pg_sql_caller/bulk_update_spec.rb --tag benchmark
> ```

## Security

`PgSqlCaller` is built so that **values are always bound through ActiveRecord's sanitizer and never interpolated into SQL**:

- All `?` placeholders in reading/writing methods are sanitized by `sanitize_sql_array` (quoted and escaped).
- `BulkUpdate` binds every value as a typed PostgreSQL array; the only identifiers placed into its SQL are restricted to the model's own column names (validated against `column_names`), so the statement is injection-safe by construction — even values like `"'); DROP TABLE employees;--"` are stored verbatim as data.

What is **your** responsibility: any SQL fragment, table name, or column name you build into a statement string yourself (rather than passing as a `?` binding) is run as-is. Use `quote_column_name`, `quote_table_name`, and `quote_value` for those, and never interpolate untrusted input directly into the SQL string.

The repository's CI runs RuboCop, `bundle-audit` (dependency CVEs), CodeQL, and Semgrep (including a custom SQL-injection ruleset) on every change.

## Versioning & changelog

This project adheres to [Semantic Versioning](https://semver.org). Given a `MAJOR.MINOR.PATCH` version, breaking API changes bump `MAJOR`, backward-compatible additions bump `MINOR`, and fixes bump `PATCH`.

All notable changes are recorded in [CHANGELOG.md](CHANGELOG.md), which follows the [Keep a Changelog](https://keepachangelog.com) format. Unreleased changes are listed there before each release.

## Development

After checking out the repo:

```sh
bin/setup                                   # install dependencies
cp spec/config/database.github.yml spec/config/database.yml   # then edit credentials as needed
psql -c 'CREATE DATABASE pg_sql_caller_test;'                  # create the test database
bundle exec rake spec                       # run the tests
```

`bin/console` gives you an interactive prompt to experiment.

To test against a specific Rails version, use one of the bundled gemfiles:

```sh
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rspec
```

Available: `rails_7_1`, `rails_7_2`, `rails_8_0`, `rails_8_1`.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `lib/pg_sql_caller/version.rb`, then run `bundle exec rake release`, which creates a git tag, pushes commits and tags, and pushes the `.gem` to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/didww/pg_sql_caller. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/didww/pg_sql_caller/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the PgSqlCaller project's codebases, issue trackers, chat rooms, and mailing lists is expected to follow the [code of conduct](https://github.com/didww/pg_sql_caller/blob/master/CODE_OF_CONDUCT.md).
