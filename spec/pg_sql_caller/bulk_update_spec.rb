# frozen_string_literal: true

RSpec.describe PgSqlCaller::BulkUpdate do
  subject { described_class.call(Employee, attrs_list) }

  let!(:dep)       { Department.create!(name: 'Tech') }
  let!(:other_dep) { Department.create!(name: 'Sales') }

  let!(:first)  { Employee.create!(name: 'John', department_id: dep.id) }
  let!(:second) { Employee.create!(name: 'Jane', department_id: dep.id) }
  # Untouched by every attrs_list below — guards against an over-broad UPDATE.
  let!(:bystander) { Employee.create!(name: 'Jake', department_id: dep.id) }

  let(:attrs_list) do
    [
      { id: first.id, name: 'John Updated', department_id: other_dep.id },
      { id: second.id, name: 'Jane Updated', department_id: other_dep.id }
    ]
  end

  it 'returns the number of rows affected' do
    expect(subject).to eq(2)
  end

  it 'writes each row its own per-column values', :aggregate_failures do
    subject
    expect(first.reload).to have_attributes(name: 'John Updated', department_id: other_dep.id)
    expect(second.reload).to have_attributes(name: 'Jane Updated', department_id: other_dep.id)
  end

  it 'touches only the listed rows' do
    expect { subject }.not_to(change { bystander.reload.attributes })
  end

  it 'leaves unlisted columns untouched' do
    expect { subject }.not_to(change { first.reload.created_at })
  end

  context 'with values that would break naive string interpolation' do
    let(:attrs_list) do
      [{ id: first.id, name: "boom'); DROP TABLE employees;--\n\"quoted\", {brace}" }]
    end

    it 'stores the raw text verbatim' do
      subject
      expect(first.reload.name).to eq("boom'); DROP TABLE employees;--\n\"quoted\", {brace}")
    end
  end

  context 'with datetime columns' do
    let(:created_at) { Time.now - 3 }
    let(:attrs_list) { [{ id: first.id, created_at: created_at }] }

    it 'round-trips the timestamp' do
      subject
      expect(first.reload.created_at).to be_within(1).of(created_at)
    end
  end

  context 'with a composite unique_by' do
    subject { described_class.call(Employee, attrs_list, unique_by: %i[department_id name]) }

    let(:new_created_at) { Time.now - 100 }
    let(:attrs_list) do
      [
        { department_id: dep.id, name: 'John', created_at: new_created_at },
        { department_id: dep.id, name: 'Jane', created_at: new_created_at }
      ]
    end

    it 'matches rows on every key column', :aggregate_failures do
      expect(subject).to eq(2)
      expect(first.reload.created_at).to be_within(1).of(new_created_at)
      expect(second.reload.created_at).to be_within(1).of(new_created_at)
      # 'Jake' shares the department but not the name, so the composite key skips it.
      expect(bystander.reload.created_at).not_to be_within(1).of(new_created_at)
    end
  end

  context 'when attrs_list is empty' do
    let(:attrs_list) { [] }

    it 'is a no-op returning zero' do
      expect { expect(subject).to eq(0) }.not_to(change { first.reload.attributes })
    end
  end

  context 'when a row omits the unique_by column' do
    let(:attrs_list) { [{ name: 'Nameless' }] }

    it 'raises ArgumentError' do
      expect { subject }.to raise_error(ArgumentError, /include unique_by/)
    end
  end

  context 'when a column does not exist on the model' do
    let(:attrs_list) { [{ id: first.id, bogus_column: 1 }] }

    it 'raises ArgumentError before touching the database', :aggregate_failures do
      expect { subject }.to raise_error(ArgumentError, /unknown.*bogus_column/)
      expect(first.reload.name).to eq('John')
    end
  end

  context 'when rows carry only the unique_by column' do
    let(:attrs_list) { [{ id: first.id }, { id: second.id }] }

    it 'raises ArgumentError rather than building empty SET SQL', :aggregate_failures do
      expect { subject }.to raise_error(ArgumentError, /no value columns/)
      expect(first.reload.name).to eq('John')
    end
  end

  context 'when rows do not all share the same keys' do
    let(:attrs_list) do
      [
        { id: first.id, name: 'John Updated' },
        { id: second.id, department_id: other_dep.id }
      ]
    end

    it 'raises ArgumentError before touching the database', :aggregate_failures do
      expect { subject }.to raise_error(ArgumentError, /differ from first row/)
      expect(first.reload.name).to eq('John')
    end
  end

  # Excluded from the default suite (see filter_run_excluding :benchmark).
  # Run with: bundle exec rspec spec/pg_sql_caller/bulk_update_spec.rb --tag benchmark
  describe 'performance vs N update_all calls in a transaction', :benchmark do
    let(:row_count) { 500 }

    # Cheap, callback-free bulk insert of NEW rows, so setup cost doesn't dwarf
    # the thing being measured.
    let(:ids) do
      bulk_dep = Department.create!(name: 'Bulk')
      now = Time.now
      rows = Array.new(row_count) do |i|
        { department_id: bulk_dep.id, name: "Employee #{i}", created_at: now, updated_at: now }
      end
      Employee.insert_all(rows)
      # Only the rows just inserted — excludes the outer let!s, so attrs_list
      # stays exactly row_count and the printed `rows=` count is accurate.
      Employee.where(department_id: bulk_dep.id).order(:id).pluck(:id)
    end

    let(:attrs_list) do
      ids.map { |id| { id: id, name: "Updated #{id}" } }
    end

    def best_of_three
      Array.new(3) {
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      }.min
    end

    it 'is faster than updating each row in a loop' do
      attrs_list # build the payload and seed the rows before timing

      loop_time = best_of_three do
        attrs_list.each do |attrs|
          Employee.where(id: attrs[:id]).update_all(attrs.except(:id))
        end
      end
      bulk_time = best_of_three { described_class.call(Employee, attrs_list) }

      loop_ms = (loop_time * 1000).round(1)
      bulk_ms = (bulk_time * 1000).round(1)
      speedup = (loop_time / bulk_time).round(1)
      warn "\n[BulkUpdate benchmark] rows=#{row_count}  " \
           "N×update_all=#{loop_ms}ms  BulkUpdate=#{bulk_ms}ms  speedup=#{speedup}×\n"
      expect(bulk_time).to be < loop_time
    end
  end
end
