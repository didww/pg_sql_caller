# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'active_support/logger'
require 'active_record'

config = YAML.load_file('spec/config/database.yml')
ActiveRecord::Base.establish_connection config['test']

if ENV['CI']
  ActiveRecord::Base.logger = ActiveSupport::Logger.new($stdout)
else
  FileUtils.mkdir_p 'tmp'
  ActiveRecord::Base.logger = ActiveSupport::Logger.new('tmp/test.log')
end

ActiveRecord::Base.logger.level = :debug
ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  begin
    drop_table :employees
  rescue StandardError
    nil
  end
  begin
    drop_table :departments
  rescue StandardError
    nil
  end

  create_table :departments do |t|
    t.string :name, null: false
    t.timestamps null: false
  end

  create_table :employees do |t|
    t.integer :department_id, null: false
    t.string :name, null: false
    t.timestamps null: false
  end
end

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

class Department < ApplicationRecord
  self.table_name = 'departments'
end

class Employee < ApplicationRecord
  self.table_name = 'employees'
  belongs_to :department, class_name: 'Department'
end
