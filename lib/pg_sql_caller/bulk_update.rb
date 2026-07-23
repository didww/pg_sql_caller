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
  # Narrow which rows are eligible with `condition`, and rewrite how individual columns are
  # assigned with `set_override` — both are raw SQL fragments, interpolated verbatim:
  #
  #   PgSqlCaller::BulkUpdate.call(Order, [{ id: 1, status: 'processing' }],
  #                                condition: "t.status = 'pending'")
  #
  #   PgSqlCaller::BulkUpdate.call(
  #     Order,
  #     [{ id: 1, status: 'delivered', delivered_at: now }],
  #     set_override: {
  #       status: "CASE WHEN t.status = 'pending' THEN v.status ELSE t.status END"
  #     }
  #   )
  #
  # Qualify every column reference in those fragments with `t.` (the target table) or `v.`
  # (the unnest source): both aliases expose the same column names, so an unqualified
  # reference raises `column reference "..." is ambiguous`.
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
  # model's own columns, so the statement is injection-safe by construction. The exception
  # is `condition` and the `set_override` expressions: those are raw SQL supplied by the
  # caller and interpolated verbatim, so they must never be built from untrusted input.
  class BulkUpdate
    # Build and run a bulk update in one call.
    #
    # @param model_class [Class<ActiveRecord::Base>] the model whose table is updated
    # @param attrs_list [Array<Hash>] one hash per row; each MUST include every
    #   `unique_by` column, and all hashes MUST share the same keys
    # @param unique_by [Symbol, String, Array<Symbol>, Array<String>] the match column(s) —
    #   a single column, or all parts of a composite key (default +:id+)
    # @param returning [Symbol, Array<Symbol>, nil] column(s) to read back from each
    #   updated row via SQL `RETURNING`; +nil+ (default) keeps the row-count behavior
    # @param condition [String, nil] an extra raw-SQL predicate ANDed onto the match
    #   clause, so only rows also satisfying it are updated; +nil+ (default) adds nothing
    # @param set_override [Hash{Symbol, String => String}] raw-SQL expressions replacing the
    #   default +v.col+ assignment of the named columns (default +{}+)
    # @return [Integer, Array<Hash{Symbol => Object}>] the number of rows affected, or —
    #   when +returning+ is given — the updated rows as type-cast, Symbol-keyed hashes
    def self.call(model_class, attrs_list, unique_by: :id, returning: nil, condition: nil, set_override: {})
      new(
        model_class,
        attrs_list,
        unique_by: unique_by,
        returning: returning,
        condition: condition,
        set_override: set_override
      ).call
    end

    attr_reader :model_class, :unique_by, :attrs_list, :returning, :condition, :set_override

    # @param model_class [Class<ActiveRecord::Base>] the model whose table is updated
    # @param attrs_list [Array<Hash>] one hash per row; each MUST include every
    #   `unique_by` column, and all hashes MUST share the same keys
    # @param unique_by [Symbol, String, Array<Symbol>, Array<String>] the match column(s) —
    #   a single column, or all parts of a composite key (default +:id+)
    # @param returning [Symbol, Array<Symbol>, nil] column(s) to read back from each
    #   updated row via SQL `RETURNING`; +nil+ (default) keeps the row-count behavior
    # @param condition [String, nil] an extra raw-SQL predicate ANDed onto the match
    #   clause, so only rows also satisfying it are updated; +nil+ (default) adds nothing
    # @param set_override [Hash{Symbol, String => String}] raw-SQL expressions replacing the
    #   default +v.col+ assignment of the named columns (default +{}+)
    def initialize(model_class, attrs_list, unique_by: :id, returning: nil, condition: nil, set_override: {})
      @model_class = model_class
      @attrs_list = attrs_list
      @unique_by = Array(unique_by).map(&:to_sym)
      @returning = returning.nil? ? nil : Array(returning)
      @condition = condition
      @set_override = set_override.to_h.transform_keys(&:to_sym)
    end

    # Execute the bulk update as a single `UPDATE ... FROM unnest(...)` statement.
    #
    # @return [Integer, Array<Hash{Symbol => Object}>] without +returning+, the number of
    #   rows affected (0 when +attrs_list+ is empty); with +returning+, the updated rows as
    #   type-cast, Symbol-keyed hashes (+[]+ when +attrs_list+ is empty)
    # @raise [ArgumentError] if a row omits a `unique_by` column, names a column that does
    #   not exist on the model, +returning+ is empty or names an unknown column,
    #   +condition+ is blank, or +set_override+ names an unknown or `unique_by` column
    #   or carries a blank expression
    def call
      validate!
      return empty_result if attrs_list.empty?

      if returning.nil?
        sql_caller.execute(build_sql, *bindings).cmd_tuples
      else
        sql_caller.select_all_serialized(build_sql, *bindings)
      end
    end

    # The full `UPDATE ... FROM unnest(...)` statement, with one `?` placeholder per
    # column for the value arrays, plus a `RETURNING` clause when +returning+ was given.
    # Public so the generated SQL can be inspected and asserted on directly: it runs the
    # very same validations as {#call}, so an input {#call} would reject never yields a
    # statement here either. An empty +attrs_list+ has no statement at all ({#call}
    # short-circuits to {#empty_result} instead of building one), so it raises.
    #
    # @return [String]
    # @raise [ArgumentError] on any input {#call} rejects (see {#validate!} and
    #   {#validate_columns!}), or when +attrs_list+ is empty
    def sql
      validate!
      raise ArgumentError, 'attrs_list must not be empty to build SQL' if attrs_list.empty?

      build_sql
    end

    private

    # Assemble the statement itself, with no validation of its own: {#call} and {#sql} each
    # validate before reaching here, so this is only ever called on inputs already checked
    # and on a non-empty +attrs_list+.
    #
    # @return [String]
    # @raise [ArgumentError] via {#validate_columns!} on first use of {#columns}
    def build_sql
      statement = <<~SQL.squish
        UPDATE #{model_class.quoted_table_name} AS t
        SET #{set_clause}
        FROM unnest(#{unnest_args}) AS v(#{column_aliases})
        WHERE #{where_clause}
      SQL
      return statement if returning.nil?

      "#{statement} RETURNING #{returning_clause}"
    end

    # The value returned for an empty +attrs_list+: a zero row count, or an empty row set
    # when +returning+ was requested — mirroring the shape {#call} returns when it runs.
    #
    # @return [Integer, Array]
    def empty_result
      returning.nil? ? 0 : []
    end

    # Validate every option that does not depend on the payload — the entry point of both
    # {#call} and {#sql}, so the two reject exactly the same inputs. {#call} runs it before
    # its empty-+attrs_list+ short-circuit, so bad options raise even when there is nothing
    # to update. The payload's own columns are validated separately, by {#validate_columns!}
    # on first use of {#columns}.
    #
    # @return [void]
    # @raise [ArgumentError] if +returning+, +condition+ or +set_override+ is invalid
    def validate!
      validate_returning! unless returning.nil?
      validate_condition! unless condition.nil?
      validate_set_override! unless set_override.empty?
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

    # Validate the extra `WHERE` predicate before any SQL runs. Its contents are raw SQL and
    # cannot be checked further — only that something was actually given, so a blank string
    # never silently produces `... AND ()`.
    #
    # @return [void]
    # @raise [ArgumentError] if +condition+ is blank
    def validate_condition!
      raise ArgumentError, 'condition must not be blank' if condition.to_s.strip.empty?
    end

    # Validate the `SET` overrides before any SQL runs: every key must be a real column of the
    # model (it becomes a quoted assignment target) and must not be one of the `unique_by`
    # columns (rewriting a match column would change the very key the row was found by), and
    # every expression must be non-blank so no assignment is left dangling. The expressions
    # themselves are raw SQL and cannot be checked further.
    #
    # @return [void]
    # @raise [ArgumentError] if a key is unknown or a `unique_by` column, or a value is blank
    def validate_set_override!
      unknown = set_override.keys.map(&:to_s) - model_class.column_names
      raise ArgumentError, "unknown #{model_class} set_override columns: #{unknown.join(', ')}" if unknown.any?

      overridden_keys = set_override.keys & unique_by
      raise ArgumentError, "set_override must not override unique_by #{overridden_keys.inspect}" if overridden_keys.any?

      blank = set_override.select { |_col, expression| expression.to_s.strip.empty? }.keys
      raise ArgumentError, "set_override expressions must not be blank: #{blank.inspect}" if blank.any?
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
    # be present, at least one column must be assigned (a value column, or a `set_override`
    # expression standing in for one), every column must exist on the model, and every row
    # must carry the same key set as the first row (so no row silently writes NULLs or
    # drops extra keys).
    #
    # @param cols [Array<Symbol>] the columns taken from the first row
    # @return [void]
    # @raise [ArgumentError] if a `unique_by` column is missing, there is nothing to
    #   assign, a column is unknown, or a row's keys differ from the first row
    def validate_columns!(cols)
      missing = unique_by - cols
      raise ArgumentError, "attrs_list rows must include unique_by #{missing.inspect}" if missing.any?

      if (cols - unique_by).empty? && set_override.empty?
        raise ArgumentError, "attrs_list has no value columns to update (only unique_by #{unique_by.inspect})"
      end

      unknown = cols.map(&:to_s) - model_class.column_names
      raise ArgumentError, "unknown #{model_class} columns: #{unknown.join(', ')}" if unknown.any?

      sorted = cols.sort
      attrs_list.each_with_index do |attrs, index|
        next if attrs.keys.sort == sorted

        raise ArgumentError, "attrs_list[#{index}] keys #{attrs.keys.inspect} differ from first row #{cols.inspect}"
      end
    end

    # The `RETURNING t.col, ...` projection. Each column is qualified with the target
    # alias `t` because the `unnest` source alias `v` shares the same column names, so an
    # unqualified `RETURNING` would be ambiguous.
    #
    # @return [String]
    def returning_clause
      returning.map { |col| "t.#{quoted(col)}" }.join(', ')
    end

    # The `SET col = v.col, ...` assignments: one per value column, in payload order, each
    # taking its raw-SQL `set_override` expression in place of `v.col` when one was given —
    # followed by the overrides that name a column absent from the payload, which contribute
    # an assignment of their own (there is no `v.col` for them to replace).
    #
    # @return [String]
    def set_clause
      extra_columns = set_override.keys - value_columns
      (value_columns + extra_columns).map { |col|
        "#{quoted(col)} = #{set_override.fetch(col) { "v.#{quoted(col)}" }}"
      }.join(', ')
    end

    # The `WHERE` clause: the key match, narrowed by the raw-SQL +condition+ when one was
    # given. The condition is parenthesized so a top-level `OR` inside it cannot widen the
    # match beyond the join keys.
    #
    # @return [String]
    def where_clause
      return match_clause if condition.nil?

      "#{match_clause} AND (#{condition})"
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
        encode_column_array(col, values)
      end
    end

    # Encode one column's values as a PostgreSQL array literal for its `?::<sql_type>[]`
    # placeholder. Temporal columns are encoded at full microsecond precision: PostgreSQL's
    # default timestamp/time array encoder formats elements via Ruby's `Time#to_s`, which
    # truncates to whole seconds — silently corrupting writes and, worse, breaking any
    # `unique_by` match on a sub-second key (the truncated bind never equals the stored
    # sub-second value, so the row is missed). Non-temporal columns use the standard
    # typed-array encoder unchanged.
    #
    # @param col [Symbol] the column name
    # @param values [Array] the per-row values for that column
    # @return [String] a PostgreSQL array literal
    def encode_column_array(col, values)
      ar_type = model_class.type_for_attribute(col.to_s)
      case ar_type.type
      when :datetime then format_date_time_array(ar_type, values, include_date: true)
      when :time     then format_date_time_array(ar_type, values, include_date: false)
      else sql_caller.typecast_array(values, type: ar_type.type)
      end
    end

    # Build a `{...}` array literal of microsecond-precision temporal literals, reparsed to
    # the column's real type by the surrounding `?::<sql_type>[]` cast with no precision
    # loss. When `include_date` is set (`datetime` columns) the value is normalized to UTC and
    # suffixed `+00:00` — correct for both `timestamp` (the offset is ignored) and `timestamptz`
    # (the offset is honored); otherwise (`time` columns) only the wall-clock time of day is
    # emitted, with no date or zone. Each element is built from a value already cast to a Time
    # and then `strftime`'d into a fixed numeric format, so the literal can hold only
    # `[-0-9:. +]` and needs no escaping. `nil` becomes SQL `NULL`.
    #
    # @param ar_type [ActiveRecord::Type::Value] the column's cast type, used to coerce each
    #   value to a Time
    # @param values [Array] the per-row values for that column
    # @param include_date [Boolean] true for `datetime` (date + time, normalized to UTC),
    #   false for `time` (time of day only)
    # @return [String] a PostgreSQL array literal
    def format_date_time_array(ar_type, values, include_date:)
      elements = values.map do |value|
        time = ar_type.cast(value)
        next 'NULL' if time.nil?

        time = time.utc if include_date
        formatted = include_date ? time.strftime('%Y-%m-%d %H:%M:%S.%6N%:z') : time.strftime('%H:%M:%S.%6N')
        %("#{formatted}")
      end
      "{#{elements.join(',')}}"
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
