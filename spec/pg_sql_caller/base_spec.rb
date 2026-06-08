# frozen_string_literal: true

RSpec.describe PgSqlCaller::Base do
  it 'performs select_values correctly' do
    dep = Department.create! name: 'Tech'
    employees = Employee.create!(
      [
        { name: 'John Doe', department_id: dep.id },
        { name: 'Jane Doe', department_id: dep.id }
      ]
    )

    dep2 = Department.create! name: 'Sales'
    Employee.create! name: 'Jake Doe', department_id: dep2.id

    expect(
      described_class.select_values('select name from employees where department_id = ?', dep.id)
    ).to match_array(employees.map(&:name))
  end

  it 'performs transaction_open? correctly' do
    expect(described_class.transaction_open?).to be(false)
    described_class.transaction do
      expect(described_class.transaction_open?).to be(true)
    end
    ApplicationRecord.transaction do
      expect(described_class.transaction_open?).to be(true)
    end
  end
end
