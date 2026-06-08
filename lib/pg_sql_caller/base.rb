# frozen_string_literal: true

require 'singleton'
require 'active_support/core_ext/class/attribute'
require 'active_support/core_ext/module/delegation'
require 'active_support/core_ext/string/inflections'
require 'pg_sql_caller/model'

module PgSqlCaller
  # Class-level, app-wide facade over a single shared Model instance (a Singleton).
  # Declare the ActiveRecord class once, then call the same SQL methods directly on
  # the class — every call is forwarded to `.instance`.
  #
  #   class Sql < PgSqlCaller::Base
  #     model_class 'ApplicationRecord' # a String (constantized on first use) or the Class itself
  #   end
  #
  #   Sql.select_value('SELECT count(*) FROM users WHERE active = ?', true) # => 42
  #   Sql.transaction { Sql.execute('DELETE FROM logs') }
  #
  # `PgSqlCaller::Base` can also be configured and used directly:
  #
  #   PgSqlCaller::Base.model_class ApplicationRecord
  #   PgSqlCaller::Base.current_database # => 'my_db'
  #
  # Every public {PgSqlCaller::Model} instance method is available as a class method here.
  #
  # @see PgSqlCaller::Model
  class Base < Model
    include Singleton

    # @!method self.instance
    #   The shared singleton instance (from Ruby's Singleton) that every class-level
    #   call is delegated to. Built on first access.
    #   @return [PgSqlCaller::Base]

    class_attribute :_model_class, instance_writer: false

    class << self
      # Configure which ActiveRecord class backs this caller — the class itself or its
      # name as a String (constantized lazily on first use). Call once, at boot.
      #
      #   PgSqlCaller::Base.model_class ApplicationRecord
      #
      # @param klass [Class<ActiveRecord::Base>, String] the class, or its name
      # @return [Class<ActiveRecord::Base>, String] the value just set
      def model_class(klass)
        self._model_class = klass
      end

      # Forward any unknown class-level call to the shared Singleton instance —
      # e.g. `Base.select_value(...)` runs `Base.instance.select_value(...)`. This
      # covers every public Model instance method (including ones added later via
      # `define_sql_method`) without maintaining an explicit list.
      delegate_missing_to :instance
    end

    # Build the singleton instance. Invoked once by {.instance}; never called directly
    # (Singleton makes +.new+ private). Resolves the configured {.model_class} name/class
    # into a Class for {#model_class}.
    #
    # @raise [NotImplementedError] if {.model_class} was never configured
    def initialize
      raise NotImplementedError, "define model_class in #{self.class}" if _model_class.nil?

      @model_class = _model_class.is_a?(String) ? _model_class.constantize : _model_class
    end
  end
end
