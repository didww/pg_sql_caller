# frozen_string_literal: true

require 'active_support/core_ext/string/filters'
require 'pg_sql_caller/model'

module PgSqlCaller
  # Bulk partial-update of existing rows keyed by one or more columns, via
  # `UPDATE ... FROM unnest(...)`:
  #
  #   PgSqlCaller::BulkUpdate.call(Employee, [
  #     { id: 1, name: 'John', department_id: 10 },
  #     { id: 2, name: 'Jane', department_id: 20 }
  #   ])
  #
  # Match on a composite key (or any custom set of uniqueness columns) by passing
  # `unique_by` an array instead of a single column:
  #
  #   PgSqlCaller::BulkUpdate.call(Employee, attrs_list, unique_by: %i[department_id name])
  #
  # Chosen over `upsert_all`: PostgreSQL NOT NULL-checks the candidate INSERT tuple of
  # `INSERT ... ON CONFLICT DO UPDATE` *before* conflict arbitration, so upsert rejects
  # partial payloads that omit the table's other NOT NULL columns. This join only ever
  # touches the listed columns of rows that already exist.
  #
  # Preferred over N separate `update_all` calls wrapped in a transaction: a transaction
  # makes those writes atomic but does nothing to batch them — it is still N statements,
  # N client<->server round-trips, and N parse/plan cycles. This is a single statement
  # and a single round-trip; PostgreSQL applies the whole set-based update server-side.
  # Round-trip latency dominates the N-call approach as the row count grows, so this stays
  # roughly flat while the loop scales linearly (see
  # spec/pg_sql_caller/bulk_update_spec.rb benchmark).
  #
  # Each column is sent as one typed PostgreSQL array; `unnest` zips the arrays back
  # into rows. Values are bound through ActiveRecord's sanitizer (PgSqlCaller::Model) and
  # never interpolated; the only identifiers placed into the SQL are restricted to the
  # model's own columns, so the statement is injection-safe by construction.
  class BulkUpdate
    # Build and run a bulk update in one call.
    #
    # @param model_class [Class<ActiveRecord::Base>] the model whose table is updated
    # @param attrs_list [Array<Hash>] one hash per row; each MUST include every
    #   `unique_by` column, and all hashes MUST share the same keys
    # @param unique_by [Symbol, Array<Symbol>] the match column(s) — a single column,
    #   or all parts of a composite key (default +:id+)
    # @param returning [Symbol, Array<Symbol>, nil] column(s) to read back from each
    #   updated row via SQL `RETURNING`; +nil+ (default) keeps the row-count behavior
    # @return [Integer, Array<Hash{Symbol => Object}>] the number of rows affected, or —
    #   when +returning+ is given — the updated rows as type-cast, Symbol-keyed hashes
    def self.call(model_class, attrs_list, unique_by: :id, returning: nil)
      new(model_class, attrs_list, unique_by: unique_by, returning: returning).call
    end

    attr_reader :model_class, :unique_by, :attrs_list, :returning

    # @param model_class [Class<ActiveRecord::Base>] the model whose table is updated
    # @param attrs_list [Array<Hash>] one hash per row; each MUST include every
    #   `unique_by` column, and all hashes MUST share the same keys
    # @param unique_by [Symbol, Array<Symbol>] the match column(s) — a single column,
    #   or all parts of a composite key (default +:id+)
    # @param returning [Symbol, Array<Symbol>, nil] column(s) to read back from each
    #   updated row via SQL `RETURNING`; +nil+ (default) keeps the row-count behavior
    def initialize(model_class, attrs_list, unique_by: :id, returning: nil)
      @model_class = model_class
      @attrs_list = attrs_list
      @unique_by = Array(unique_by)
      @returning = returning.nil? ? nil : Array(returning)
    end

    # Execute the bulk update as a single `UPDATE ... FROM unnest(...)` statement.
    #
    # @return [Integer, Array<Hash{Symbol => Object}>] without +returning+, the number of
    #   rows affected (0 when +attrs_list+ is empty); with +returning+, the updated rows as
    #   type-cast, Symbol-keyed hashes (+[]+ when +attrs_list+ is empty)
    # @raise [ArgumentError] if a row omits a `unique_by` column, names a column that does
    #   not exist on the model, or +returning+ is empty or names an unknown column
    def call
      validate_returning! unless returning.nil?
      return empty_result if attrs_list.empty?

      if returning.nil?
        sql_caller.execute(sql, *bindings).cmd_tuples
      else
        sql_caller.select_all_serialized(sql, *bindings)
      end
    end

    private

    # The value returned for an empty +attrs_list+: a zero row count, or an empty row set
    # when +returning+ was requested — mirroring the shape {#call} returns when it runs.
    #
    # @return [Integer, Array]
    def empty_result
      returning.nil? ? 0 : []
    end

    # Validate the requested `RETURNING` columns before any SQL runs: at least one column
    # must be named, and every column must exist on the model (each is qualified with the
    # target alias `t`, so it must be a real column, never an expression).
    #
    # @return [void]
    # @raise [ArgumentError] if +returning+ is empty or names a column unknown to the model
    def validate_returning!
      raise ArgumentError, 'returning must name at least one column' if returning.empty?

      unknown = returning.map(&:to_s) - model_class.column_names
      raise ArgumentError, "unknown #{model_class} returning columns: #{unknown.join(', ')}" if unknown.any?
    end

    # The SQL executor, built from the model's own connection: it sanitizes the bound
    # values, runs the statement and encodes the typed PostgreSQL arrays.
    #
    # @return [PgSqlCaller::Model]
    def sql_caller
      @sql_caller ||= PgSqlCaller::Model.new(model_class)
    end

    # Columns to write, taken from the first row (assumed identical across all rows).
    #
    # @return [Array<Symbol>]
    # @raise [ArgumentError] via {#validate_columns!} when the payload is invalid
    def columns
      @columns ||= attrs_list.first.keys.tap { |cols| validate_columns!(cols) }
    end

    # The columns actually updated — every column except the `unique_by` match column(s).
    #
    # @return [Array<Symbol>]
    def value_columns
      @value_columns ||= columns - unique_by
    end

    # Validate the payload's columns before any SQL runs: every `unique_by` column must
    # be present, at least one value column must remain, every column must exist on the
    # model, and every row must carry the same key set as the first row (so no row
    # silently writes NULLs or drops extra keys).
    #
    # @param cols [Array<Symbol>] the columns taken from the first row
    # @return [void]
    # @raise [ArgumentError] if a `unique_by` column is missing, there are no value
    #   columns to update, a column is unknown, or a row's keys differ from the first row
    def validate_columns!(cols)
      missing = unique_by - cols
      raise ArgumentError, "attrs_list rows must include unique_by #{missing.inspect}" if missing.any?

      raise ArgumentError, "attrs_list has no value columns to update (only unique_by #{unique_by.inspect})" if (cols - unique_by).empty?

      unknown = cols.map(&:to_s) - model_class.column_names
      raise ArgumentError, "unknown #{model_class} columns: #{unknown.join(', ')}" if unknown.any?

      sorted = cols.sort
      attrs_list.each_with_index do |attrs, index|
        next if attrs.keys.sort == sorted

        raise ArgumentError, "attrs_list[#{index}] keys #{attrs.keys.inspect} differ from first row #{cols.inspect}"
      end
    end

    # The full `UPDATE ... FROM unnest(...)` statement, with one `?` placeholder per
    # column for the value arrays, plus a `RETURNING` clause when +returning+ was given.
    #
    # @return [String]
    def sql
      statement = <<~SQL.squish
        UPDATE #{model_class.quoted_table_name} AS t
        SET #{set_clause}
        FROM unnest(#{unnest_args}) AS v(#{column_aliases})
        WHERE #{match_clause}
      SQL
      return statement if returning.nil?

      "#{statement} RETURNING #{returning_clause}"
    end

    # The `RETURNING t.col, ...` projection. Each column is qualified with the target
    # alias `t` because the `unnest` source alias `v` shares the same column names, so an
    # unqualified `RETURNING` would be ambiguous.
    #
    # @return [String]
    def returning_clause
      returning.map { |col| "t.#{quoted(col)}" }.join(', ')
    end

    # The `SET col = v.col, ...` assignments for the value columns.
    #
    # @return [String]
    def set_clause
      value_columns.map { |col| "#{quoted(col)} = v.#{quoted(col)}" }.join(', ')
    end

    # Match each row on every `unique_by` column — one column, or all parts of a composite key.
    #
    # @return [String] the `WHERE` join condition, e.g. +"t.a = v.a AND t.b = v.b"+
    def match_clause
      unique_by.map { |col| "t.#{quoted(col)} = v.#{quoted(col)}" }.join(' AND ')
    end

    # One `?` placeholder per column, cast to that column's array type so PostgreSQL
    # can resolve the otherwise-unknown bind parameter.
    #
    # @return [String] e.g. +"?::bigint[], ?::text[]"+
    def unnest_args
      columns.map { |col| "?::#{sql_type(col)}[]" }.join(', ')
    end

    # The `v(col, ...)` column alias list, in column order.
    #
    # @return [String]
    def column_aliases
      columns.map { |col| quoted(col) }.join(', ')
    end

    # One PostgreSQL array literal per column, in column order, matching the `?`s above.
    #
    # @return [Array<String>] one encoded array literal per column
    def bindings
      columns.map do |col|
        values = attrs_list.map { |attrs| attrs[col] }
        sql_caller.typecast_array(values, type: model_class.type_for_attribute(col.to_s).type)
      end
    end

    # The PostgreSQL type of a column, used to build its array cast.
    #
    # @param col [Symbol] a column name
    # @return [String] the column's SQL type (e.g. +"bigint"+, +"timestamp without time zone"+)
    def sql_type(col)
      model_class.columns_hash.fetch(col.to_s).sql_type
    end

    # Quote a column-name identifier for safe inclusion in the SQL.
    #
    # @param identifier [Symbol, String] a column name
    # @return [String] the quoted identifier
    def quoted(identifier)
      sql_caller.quote_column_name(identifier)
    end
  end
end
