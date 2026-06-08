# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-08

### Added

- `PgSqlCaller::Model` — a standalone, instantiable class holding the SQL API.
  Build one directly with `PgSqlCaller::Model.new(ApplicationRecord)`; `PgSqlCaller::Base`
  is now a thin `Singleton` facade subclassing it.
- `PgSqlCaller::BulkUpdate` — partial update of many existing rows in a single
  `UPDATE ... FROM unnest(...)` statement and round-trip, with single- or composite-column
  `unique_by` matching and column validation.
- `quote_value`, `quote_column_name`, and `quote_table_name` quoting helpers.
- `with_min_messages(level)` — temporarily set the connection's `client_min_messages`
  around a block.
- `with_notice_processor(callback)` — capture PostgreSQL `NOTICE` output emitted during a block.
- `define_sql_method` (single-name) helper; the variadic `define_sql_methods` is retained for
  backward compatibility.
- CI test matrix against Rails 7.1, 7.2, 8.0, and 8.1 (bundled `gemfiles/`).

### Changed

- **BREAKING**: Minimum Ruby raised to `>= 3.2.0` (was `>= 2.3.0`).
- **BREAKING**: `activerecord` and `activesupport` now require `>= 7.1` (previously unconstrained).
- `PgSqlCaller::Base` now forwards class-level calls to its singleton instance via
  `delegate_missing_to`, so every public `Model` instance method is available as a class
  method automatically.
- **BREAKING**: `current_database_name` was renamed to `current_database`.

### Removed

- **BREAKING**: The custom `Forwardable`-based `delegate` macro on `Base`, superseded by
  ActiveSupport delegation and `delegate_missing_to`.

## [0.2.3] - 2025-02-07

### Fixed

- `select_value_serialized` no longer raises when the query returns no rows; it now
  returns `nil`.

## [0.2.2] - 2023-02-08

### Fixed

- The class-level `PgSqlCaller::Base.connection` call now resolves correctly (delegated
  to the singleton instance).

## [0.2.1] - 2023-02-08

### Added

- `connection` exposed as a public method on the caller.

## [0.2.0] - 2020-12-23

### Added

- `select_value_serialized` and `select_values_serialized` type-cast reads.
- `next_sequence_value` to peek at a table's next sequence value.
- `table_full_size` and `table_data_size` relation-size helpers.

### Fixed

- Serialized reads no longer raise on columns whose type is unknown; the raw value is
  returned unchanged.

### Changed

- Homepage moved to the `didww` organization.

## [0.1.0] - 2020-03-24

### Added

- Initial release: `PgSqlCaller::Base` singleton facade over an ActiveRecord class,
  with `?`-bound, sanitized SQL helpers — `select_value`, `select_values`, `select_all`,
  `select_rows`, `select_row`, `execute`, `select_all_serialized`, `transaction`,
  `transaction_open?`, `explain_analyze`, `typecast_array`, `sanitize_sql_array`, and
  `current_database_name`.

[1.0.0]: https://github.com/didww/pg_sql_caller/compare/v0.2.3...v1.0.0
[0.2.3]: https://github.com/didww/pg_sql_caller/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/didww/pg_sql_caller/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/didww/pg_sql_caller/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/didww/pg_sql_caller/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/didww/pg_sql_caller/releases/tag/v0.1.0
