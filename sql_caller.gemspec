# frozen_string_literal: true

require_relative 'lib/pg_sql_caller/version'

Gem::Specification.new do |spec|
  spec.name          = 'pg_sql_caller'
  spec.version       = PgSqlCaller::VERSION
  spec.authors       = ['Denis Talakevich']
  spec.email         = ['senid231@gmail.com']

  spec.summary       = 'Postgresql Sql Caller for ActiveRecord'
  spec.description   = 'PgSqlCaller is a small, focused wrapper for running raw SQL against ' \
                       'PostgreSQL through ActiveRecord. It exposes a stable, documented API on an ' \
                       'ActiveRecord-backed class you name, covering the queries the query builder ' \
                       'makes awkward: single-scalar and single-column SELECTs, raw rows, ' \
                       'ActiveRecord::Result reads, and type-cast (serialized) variants that decode ' \
                       'PostgreSQL arrays and custom column types into Ruby objects. Every ? ' \
                       'placeholder is bound and escaped through the ActiveRecord sanitizer, so ' \
                       'statements stay injection-safe with no manual quoting. On top of that it adds ' \
                       'PostgreSQL-specific helpers — non-consuming sequence peeking, table and ' \
                       'relation sizes, EXPLAIN ANALYZE, NOTICE capture, and quoting/sanitizing ' \
                       'utilities — plus a fast, injection-safe bulk update that partially updates ' \
                       'many existing rows in a single UPDATE ... FROM unnest(...) statement and ' \
                       'round-trip. The reader API is extensible via define_sql_method, and the gem ' \
                       'runs on Ruby 3.2+ with Rails 7.1 through 8.1.'
  spec.homepage      = 'https://github.com/didww/pg_sql_caller'
  spec.license       = 'MIT'
  spec.required_ruby_version = Gem::Requirement.new('>= 3.2.0')

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = spec.homepage

  # Ship only the runtime library code plus the user-facing docs/license.
  # Everything else (specs, CI config, dev tooling, binstubs) stays out of the gem.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir['lib/**/*'].select { |f| File.file?(f) } + %w[CHANGELOG.md LICENSE.txt README.md]
  end
  spec.extra_rdoc_files = %w[README.md CHANGELOG.md]
  spec.require_paths = ['lib']

  spec.add_dependency 'activerecord', '>= 7.1'
  spec.add_dependency 'activesupport', '>= 7.1'
end
