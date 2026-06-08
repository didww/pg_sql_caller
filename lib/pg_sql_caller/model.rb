# frozen_string_literal: true

require 'active_support/core_ext/class/attribute'
require 'active_support/core_ext/module/delegation'

module PgSqlCaller
  # Wraps a single ActiveRecord class and runs raw SQL through its connection.
  # Positional `?` placeholders are bound and sanitized by ActiveRecord, so values
  # are never interpolated into the SQL string.
  #
  #   sql = PgSqlCaller::Model.new(ApplicationRecord)
  #   sql.select_value('SELECT count(*) FROM users WHERE active = ?', true) # => 42
  #   sql.select_values('SELECT email FROM users WHERE dept_id = ?', 5)     # => ['a@x', 'b@x']
  #   sql.select_all('SELECT id, name FROM users')  # => [{ 'id' => 1, 'name' => 'Jo' }, ...]
  #   sql.transaction { sql.execute('UPDATE users SET active = false') }
  #
  # The `*_serialized` variants additionally cast each value back to its Ruby type
  # using the result's column types (e.g. timestamp -> Time, int[] -> Array), and
  # key rows by Symbol:
  #
  #   sql.select_all_serialized('SELECT id, created_at FROM users')
  #   # => [{ id: 1, created_at: 2026-06-08 12:00:00 +0000 }, ...]
  class Model
    class << self
      # Define a single connection-backed SQL instance method named +name+.
      #
      # @param name [Symbol] the connection method to wrap (e.g. +:select_value+)
      # @return [Symbol] the name of the defined method
      def define_sql_method(name)
        define_method(name) do |sql, *bindings|
          sql = sanitize_sql_array(sql, *bindings) if bindings.any?
          connection.public_send(name, sql)
        end
      end

      # Define several connection-backed SQL instance methods at once — a thin wrapper
      # over {.define_sql_method}, kept for backward compatibility.
      #
      # @param names [Array<Symbol>] the connection methods to wrap
      # @return [Array<Symbol>] +names+, unchanged
      def define_sql_methods(*names)
        names.each { |name| define_sql_method(name) }
      end
    end

    # @!method select_value(sql, *bindings)
    #   Run +sql+ and return the value of the first column of the first row.
    #   @param sql [String] SQL statement, optionally containing `?` placeholders
    #   @param bindings [Array<Object>] values bound, in order, to the `?` placeholders
    #   @return [Object, nil] the single value, or nil when no row matches
    define_sql_method :select_value

    # @!method select_values(sql, *bindings)
    #   Run +sql+ and return the first column of every row.
    #   @param sql [String] SQL statement, optionally containing `?` placeholders
    #   @param bindings [Array<Object>] values bound, in order, to the `?` placeholders
    #   @return [Array<Object>]
    define_sql_method :select_values

    # @!method execute(sql, *bindings)
    #   Execute +sql+ (e.g. INSERT/UPDATE/DELETE/DDL) and return the raw adapter result.
    #   @param sql [String] SQL statement, optionally containing `?` placeholders
    #   @param bindings [Array<Object>] values bound, in order, to the `?` placeholders
    #   @return [PG::Result] the raw PostgreSQL result (e.g. +#cmd_tuples+ for affected rows)
    define_sql_method :execute

    # @!method select_all(sql, *bindings)
    #   Run +sql+ and return every row.
    #   @param sql [String] SQL statement, optionally containing `?` placeholders
    #   @param bindings [Array<Object>] values bound, in order, to the `?` placeholders
    #   @return [ActiveRecord::Result] rows as String-keyed hashes
    define_sql_method :select_all

    # @!method select_rows(sql, *bindings)
    #   Run +sql+ and return rows as arrays of column values (no column names).
    #   @param sql [String] SQL statement, optionally containing `?` placeholders
    #   @param bindings [Array<Object>] values bound, in order, to the `?` placeholders
    #   @return [Array<Array>]
    define_sql_method :select_rows

    # @return [Class<ActiveRecord::Base>] the ActiveRecord class this instance wraps
    attr_reader :model_class

    # @!method connection
    #   The ActiveRecord connection adapter of {#model_class}; every SQL method runs through it.
    #   @return [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    delegate :connection, to: :model_class

    # @!method quote_column_name(name)
    #   Quote a column-name identifier for safe inclusion in SQL (delegated to the
    #   {#connection}, since the model class itself does not expose it).
    #   @param name [String, Symbol] the column name to quote
    #   @return [String] the quoted identifier
    delegate :quote_column_name, to: :connection

    # @!method quote_table_name(name)
    #   Quote a table-name identifier for safe inclusion in SQL (delegated to the
    #   {#connection}, since the model class itself does not expose it).
    #   @param name [String, Symbol] the table name to quote
    #   @return [String] the quoted identifier
    delegate :quote_table_name, to: :connection

    # @param model_class [Class<ActiveRecord::Base>] the class whose connection is used
    #   to run statements and to sanitize/typecast values
    def initialize(model_class)
      @model_class = model_class
    end

    # Whether a database transaction is currently open on the connection.
    #
    # @return [Boolean]
    def transaction_open?
      connection.send(:transaction_open?)
    end

    # Like {#select_all}, but cast each value back to its Ruby type (using the result's
    # column types) and key every row by Symbol.
    #
    # @param sql [String] SQL statement, optionally containing `?` placeholders
    # @param bindings [Array<Object>] values bound, in order, to the `?` placeholders
    # @return [Array<Hash{Symbol => Object}>]
    def select_all_serialized(sql, *bindings)
      result = select_all(sql, *bindings)
      result.map do |row|
        row.to_h { |key, value| [key.to_sym, deserialize_result(result, key, value)] }
      end
    end

    # Like {#select_value}, but cast the value back to its Ruby type.
    #
    # @param sql [String] SQL statement, optionally containing `?` placeholders
    # @param bindings [Array<Object>] values bound, in order, to the `?` placeholders
    # @return [Object, nil] the type-cast value, or nil when no row matches
    def select_value_serialized(sql, *bindings)
      result = select_all(sql, *bindings)
      key = result.first&.keys&.first
      return if key.nil?

      value = result.first.values.first
      deserialize_result(result, key, value)
    end

    # Run +sql+ and return each row as an array of its type-cast column values.
    #
    # @param sql [String] SQL statement, optionally containing `?` placeholders
    # @param bindings [Array<Object>] values bound, in order, to the `?` placeholders
    # @return [Array<Array>] one inner array per row
    def select_values_serialized(sql, *bindings)
      result = select_all(sql, *bindings)
      result.map do |row|
        row.map { |key, value| deserialize_result(result, key, value) }
      end
    end

    # The next value of the table's `<table_name>_id_seq` sequence (its current
    # last_value + 1), read without consuming the sequence.
    #
    # @param table_name [String, Symbol]
    # @return [Integer]
    def next_sequence_value(table_name)
      select_value("SELECT last_value FROM #{table_name}_id_seq") + 1
    end

    # Total on-disk size of the table including indexes and TOAST, in bytes
    # (PostgreSQL `pg_total_relation_size`).
    #
    # @param table_name [String, Symbol]
    # @return [Integer] size in bytes
    def table_full_size(table_name)
      select_value('SELECT pg_total_relation_size(?)', table_name)
    end

    # On-disk size of the table's main data fork only, in bytes
    # (PostgreSQL `pg_relation_size`).
    #
    # @param table_name [String, Symbol]
    # @return [Integer] size in bytes
    def table_data_size(table_name)
      select_value('SELECT pg_relation_size(?)', table_name)
    end

    # Run +sql+ and return the first row as an array of column values.
    #
    # @param sql [String] SQL statement, optionally containing `?` placeholders
    # @param bindings [Array<Object>] values bound, in order, to the `?` placeholders
    # @return [Array, nil] the first row, or nil when no row matches
    def select_row(sql, *bindings)
      select_rows(sql, *bindings)[0]
    end

    # Run the given block inside a database transaction, committing on success and
    # rolling back if it raises.
    #
    # @yield executes within the open transaction
    # @return [Object] the block's return value
    # @raise [ArgumentError] if no block is given
    def transaction(&)
      raise ArgumentError, 'block must be given' unless block_given?

      connection.transaction(&)
    end

    # Run `EXPLAIN ANALYZE` for +sql+ and return the query plan as text.
    #
    # @param sql [String] the statement to analyze
    # @return [String] the plan, one line per row, prefixed with a +QUERY_PLAN+ header
    def explain_analyze(sql)
      result = select_values("EXPLAIN ANALYZE #{sql}")
      ['QUERY_PLAN', *result].join("\n")
    end

    # Encode a Ruby array into a PostgreSQL array literal for the given attribute type,
    # ready to bind as a single `?` value.
    #
    # @param values [Array] the Ruby values to encode
    # @param type [Symbol] an ActiveRecord attribute type (e.g. +:integer+, +:string+, +:datetime+)
    # @return [String] a PostgreSQL array literal, e.g. +"{1,2,3}"+
    def typecast_array(values, type:)
      type = ActiveRecord::Type.lookup(type, array: true)
      data = type.serialize(values)
      data.encoder.encode(data.values)
    end

    # Interpolate `?` placeholders in +sql+ with +bindings+ through ActiveRecord's
    # sanitizer (values are quoted/escaped, never raw-interpolated).
    #
    # @param sql [String] SQL containing `?` placeholders
    # @param bindings [Array<Object>] values bound, in order, to the placeholders
    # @return [String] the safe, ready-to-run SQL
    def sanitize_sql_array(sql, *bindings)
      model_class.send :sanitize_sql_array, bindings.unshift(sql)
    end

    # @return [String] the name of the currently connected database (`current_database()`)
    def current_database
      select_value('SELECT current_database();')
    end

    # Capture PostgreSQL NOTICE output (e.g. from +RAISE NOTICE+) emitted while the block
    # runs, passing each message to +callback+. Lowers +client_min_messages+ to +notice+
    # for the duration (see {#with_min_messages}) and restores the previous notice
    # processor afterward.
    #
    #   sql.with_notice_processor(->(msg) { logger.info(msg) }) do
    #     sql.execute("DO $$ BEGIN RAISE NOTICE 'hi'; END $$")
    #   end
    #
    # @param callback [#call] invoked with each notice message (a chomped String)
    # @yield runs with the notice processor installed
    # @return [Object] the block's return value
    def with_notice_processor(callback)
      with_min_messages('notice') do
        old_processor = connection.raw_connection.set_notice_processor { |result| callback.call(result.to_s.chomp) }
        yield
      ensure
        connection.raw_connection.set_notice_processor(&old_processor)
      end
    end

    # Temporarily set the connection's +client_min_messages+ to +level+ for the duration
    # of the block, restoring the previous value afterward.
    #
    # @param level [String] one of: debug5, debug4, debug3, debug2, debug1, log, notice, warning, error
    # @yield runs with the level applied
    # @return [Object] the block's return value
    def with_min_messages(level)
      old_level = select_value('SHOW client_min_messages')
      execute('SET client_min_messages TO ?', level)
      yield
    ensure
      execute('SET client_min_messages TO ?', old_level) unless old_level.nil?
    end

    # Quote and escape a value as a SQL literal, safe to inline into a statement.
    #
    # @param value [Object] the value to quote (e.g. String, Numeric, nil, Time)
    # @return [String] the quoted SQL literal (e.g. +"'O''Brien'"+)
    def quote_value(value)
      connection.quote(value)
    end

    private

    # Cast a raw result value back to its Ruby type using the result set's column types.
    #
    # @param result [ActiveRecord::Result] the result the value came from (carries column types)
    # @param column_name [String] the column the value belongs to
    # @param raw_value [Object] the raw value as returned by the adapter
    # @return [Object] the type-cast value, or +raw_value+ unchanged when the column type is unknown
    def deserialize_result(result, column_name, raw_value)
      column_type = result.column_types[column_name]
      return raw_value if column_type.nil?

      column_type.deserialize(raw_value)
    end
  end
end
