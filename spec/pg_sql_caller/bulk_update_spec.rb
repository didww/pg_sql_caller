# frozen_string_literal: true

# Convention for this file: every context that exercises `.call` MUST also assert the exact
# statement it runs, as a separate `it` in that same context — `expect(builder.sql).to eq(...)`.
# Behavior and the SQL producing it stay side by side, one place per scenario, so no change to
# the generated statement can slip through unseen and every scenario is covered from both ends.
# Contexts where `.call` raises assert the same from the other end: `#sql` validates exactly what
# `.call` does, so it MUST raise the same error rather than hand back an invalid statement.
RSpec.describe PgSqlCaller::BulkUpdate do
  subject { described_class.call(Employee, attrs_list, **options) }

  # The same arguments `subject` passes to `.call`, so each context can assert its own SQL.
  let(:builder) { described_class.new(Employee, attrs_list, **options) }
  let(:options) { {} }

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

  it 'builds an UPDATE ... FROM unnest(...) statement matching on the id' do
    expect(builder.sql).to eq(
      'UPDATE "employees" AS t SET "name" = v."name", "department_id" = v."department_id" ' \
      'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
      'WHERE t."id" = v."id"'
    )
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

    it 'keeps every value in a bound array, never in the SQL' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "name" = v."name" ' \
        'FROM unnest(?::bigint[], ?::character varying[]) AS v("id", "name") ' \
        'WHERE t."id" = v."id"'
      )
    end

    it 'stores the raw text verbatim' do
      subject
      expect(first.reload.name).to eq("boom'); DROP TABLE employees;--\n\"quoted\", {brace}")
    end
  end

  context 'with datetime columns' do
    let(:created_at) { Time.now - 3 }
    let(:attrs_list) { [{ id: first.id, created_at: created_at }] }

    it 'casts the bound array to the column timestamp type' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "created_at" = v."created_at" ' \
        'FROM unnest(?::bigint[], ?::timestamp(6) without time zone[]) AS v("id", "created_at") ' \
        'WHERE t."id" = v."id"'
      )
    end

    it 'round-trips the timestamp' do
      subject
      expect(first.reload.created_at).to be_within(1).of(created_at)
    end
  end

  # PostgreSQL's default timestamp array encoder formats elements via Time#to_s, dropping
  # sub-seconds. These guard the microsecond-precision encoding for datetime arrays.
  context 'with a sub-second datetime value' do
    let(:precise) { Time.utc(2026, 6, 22, 16, 15, 8, 193_456) }
    let(:attrs_list) { [{ id: first.id, created_at: precise }] }

    it 'casts the bound array to the column timestamp type' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "created_at" = v."created_at" ' \
        'FROM unnest(?::bigint[], ?::timestamp(6) without time zone[]) AS v("id", "created_at") ' \
        'WHERE t."id" = v."id"'
      )
    end

    it 'preserves microsecond precision (not truncated to whole seconds)' do
      subject
      expect(first.reload.created_at.utc.strftime('%6N')).to eq('193456')
    end
  end

  context 'matching on a sub-second datetime unique_by key' do
    let(:options) { { unique_by: %i[created_at] } }

    let(:precise) { Time.utc(2026, 6, 22, 16, 15, 8, 193_000) }
    let(:attrs_list) { [{ created_at: precise, name: 'Matched' }] }

    before { first.update_column(:created_at, precise) }

    it 'joins on the timestamp column instead of the id' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "name" = v."name" ' \
        'FROM unnest(?::timestamp(6) without time zone[], ?::character varying[]) AS v("created_at", "name") ' \
        'WHERE t."created_at" = v."created_at"'
      )
    end

    it 'matches the row despite sub-second precision', :aggregate_failures do
      expect(subject).to eq(1)
      expect(first.reload.name).to eq('Matched')
    end
  end

  # `time` columns hit the same default-array-encoder truncation as `datetime`; these guard
  # the time-of-day encoding path (no date, no zone).
  context 'with a sub-second time value' do
    let(:shift_start) { Time.utc(2000, 1, 1, 16, 15, 8, 193_456) }
    let(:attrs_list) { [{ id: first.id, shift_start: shift_start }] }

    it 'casts the bound array to the column time type' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "shift_start" = v."shift_start" ' \
        'FROM unnest(?::bigint[], ?::time without time zone[]) AS v("id", "shift_start") ' \
        'WHERE t."id" = v."id"'
      )
    end

    it 'preserves microsecond precision (not truncated to whole seconds)' do
      subject
      expect(first.reload.shift_start.strftime('%H:%M:%S.%6N')).to eq('16:15:08.193456')
    end
  end

  context 'matching on a sub-second time unique_by key' do
    let(:options) { { unique_by: %i[shift_start] } }

    let(:shift_start) { Time.utc(2000, 1, 1, 16, 15, 8, 193_000) }
    let(:attrs_list) { [{ shift_start: shift_start, name: 'Matched' }] }

    before { first.update_column(:shift_start, shift_start) }

    it 'joins on the time column instead of the id' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "name" = v."name" ' \
        'FROM unnest(?::time without time zone[], ?::character varying[]) AS v("shift_start", "name") ' \
        'WHERE t."shift_start" = v."shift_start"'
      )
    end

    it 'matches the row despite sub-second precision', :aggregate_failures do
      expect(subject).to eq(1)
      expect(first.reload.name).to eq('Matched')
    end
  end

  context 'with a composite unique_by' do
    let(:options) { { unique_by: %i[department_id name] } }

    let(:new_created_at) { Time.now - 100 }
    let(:attrs_list) do
      [
        { department_id: dep.id, name: 'John', created_at: new_created_at },
        { department_id: dep.id, name: 'Jane', created_at: new_created_at }
      ]
    end

    it 'ANDs one equality per key column and excludes them from SET' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "created_at" = v."created_at" ' \
        'FROM unnest(?::integer[], ?::character varying[], ?::timestamp(6) without time zone[]) AS v("department_id", "name", "created_at") ' \
        'WHERE t."department_id" = v."department_id" AND t."name" = v."name"'
      )
    end

    it 'matches rows on every key column', :aggregate_failures do
      expect(subject).to eq(2)
      expect(first.reload.created_at).to be_within(1).of(new_created_at)
      expect(second.reload.created_at).to be_within(1).of(new_created_at)
      # 'Jake' shares the department but not the name, so the composite key skips it.
      expect(bystander.reload.created_at).not_to be_within(1).of(new_created_at)
    end
  end

  context 'with a unique_by given as a String' do
    let(:options) { { unique_by: 'id' } }

    it 'names the same column as the Symbol, so SET still excludes it' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "name" = v."name", "department_id" = v."department_id" ' \
        'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
        'WHERE t."id" = v."id"'
      )
    end

    it 'matches on that column', :aggregate_failures do
      expect(subject).to eq(2)
      expect(first.reload.name).to eq('John Updated')
    end
  end

  context 'when attrs_list is empty' do
    let(:attrs_list) { [] }

    it 'is a no-op returning zero' do
      expect { expect(subject).to eq(0) }.not_to(change { first.reload.attributes })
    end

    # `.call` never builds SQL here, so there is no statement for `#sql` to hand back either.
    it 'raises ArgumentError from #sql, which has no statement to build' do
      expect { builder.sql }.to raise_error(ArgumentError, /attrs_list must not be empty/)
    end
  end

  context 'when a row omits the unique_by column' do
    let(:attrs_list) { [{ name: 'Nameless' }] }

    it 'raises ArgumentError' do
      expect { subject }.to raise_error(ArgumentError, /include unique_by/)
    end

    it 'raises the same error from #sql' do
      expect { builder.sql }.to raise_error(ArgumentError, /include unique_by/)
    end
  end

  context 'when a column does not exist on the model' do
    let(:attrs_list) { [{ id: first.id, bogus_column: 1 }] }

    it 'raises ArgumentError before touching the database', :aggregate_failures do
      expect { subject }.to raise_error(ArgumentError, /unknown.*bogus_column/)
      expect(first.reload.name).to eq('John')
    end

    it 'raises the same error from #sql' do
      expect { builder.sql }.to raise_error(ArgumentError, /unknown.*bogus_column/)
    end
  end

  context 'when rows carry only the unique_by column' do
    let(:attrs_list) { [{ id: first.id }, { id: second.id }] }

    it 'raises ArgumentError rather than building empty SET SQL', :aggregate_failures do
      expect { subject }.to raise_error(ArgumentError, /no value columns/)
      expect(first.reload.name).to eq('John')
    end

    it 'raises the same error from #sql' do
      expect { builder.sql }.to raise_error(ArgumentError, /no value columns/)
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

    it 'raises the same error from #sql' do
      expect { builder.sql }.to raise_error(ArgumentError, /differ from first row/)
    end
  end

  context 'with returning:' do
    let(:options) { { returning: returning } }
    let(:returning) { %i[id name department_id] }

    it 'appends a RETURNING projection qualified with the target alias' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "name" = v."name", "department_id" = v."department_id" ' \
        'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
        'WHERE t."id" = v."id" ' \
        'RETURNING t."id", t."name", t."department_id"'
      )
    end

    it 'returns the updated rows as Symbol-keyed hashes of the listed columns', :aggregate_failures do
      result = subject
      expect(result).to contain_exactly(
        { id: first.id, name: 'John Updated', department_id: other_dep.id },
        { id: second.id, name: 'Jane Updated', department_id: other_dep.id }
      )
    end

    it 'returns the new values, not the pre-update ones' do
      expect(subject.map { |row| row[:name] }).to contain_exactly('John Updated', 'Jane Updated')
    end

    it 'returns only the listed columns' do
      expect(subject.map(&:keys)).to all(eq(%i[id name department_id]))
    end

    context 'with a single column passed as a Symbol' do
      let(:returning) { :id }

      it 'projects that one column' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "name" = v."name", "department_id" = v."department_id" ' \
          'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
          'WHERE t."id" = v."id" ' \
          'RETURNING t."id"'
        )
      end

      it 'coerces it to an Array and returns that one column' do
        expect(subject).to contain_exactly({ id: first.id }, { id: second.id })
      end
    end

    context 'with a datetime column' do
      let(:created_at) { Time.now - 60 }
      let(:attrs_list) { [{ id: first.id, created_at: created_at }] }
      let(:returning)  { %i[id created_at] }

      it 'projects the timestamp column' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "created_at" = v."created_at" ' \
          'FROM unnest(?::bigint[], ?::timestamp(6) without time zone[]) AS v("id", "created_at") ' \
          'WHERE t."id" = v."id" ' \
          'RETURNING t."id", t."created_at"'
        )
      end

      it 'type-casts each returned value to its Ruby type', :aggregate_failures do
        row = subject.first
        expect(row[:created_at]).to be_a(Time)
        expect(row[:created_at]).to be_within(1).of(created_at)
      end
    end

    context 'with a composite unique_by' do
      let(:options) { { unique_by: %i[department_id name], returning: %i[id name] } }

      let(:new_created_at) { Time.now - 100 }
      let(:attrs_list) do
        [
          { department_id: dep.id, name: 'John', created_at: new_created_at },
          { department_id: dep.id, name: 'Jane', created_at: new_created_at }
        ]
      end

      it 'projects columns that are part of the composite key' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "created_at" = v."created_at" ' \
          'FROM unnest(?::integer[], ?::character varying[], ?::timestamp(6) without time zone[]) AS v("department_id", "name", "created_at") ' \
          'WHERE t."department_id" = v."department_id" AND t."name" = v."name" ' \
          'RETURNING t."id", t."name"'
        )
      end

      it 'returns a row per matched key, skipping non-matches' do
        expect(subject).to contain_exactly({ id: first.id, name: 'John' }, { id: second.id, name: 'Jane' })
      end
    end

    context 'when attrs_list is empty' do
      let(:attrs_list) { [] }

      it 'is a no-op returning an empty array' do
        expect { expect(subject).to eq([]) }.not_to(change { first.reload.attributes })
      end

      it 'raises ArgumentError from #sql, which has no statement to build' do
        expect { builder.sql }.to raise_error(ArgumentError, /attrs_list must not be empty/)
      end
    end

    context 'when returning names an unknown column' do
      let(:returning) { %i[id bogus_column] }

      it 'raises ArgumentError before touching the database', :aggregate_failures do
        expect { subject }.to raise_error(ArgumentError, /unknown.*bogus_column/)
        expect(first.reload.name).to eq('John')
      end

      it 'raises the same error from #sql' do
        expect { builder.sql }.to raise_error(ArgumentError, /unknown.*bogus_column/)
      end
    end

    context 'when returning is empty' do
      let(:returning) { [] }

      it 'raises ArgumentError', :aggregate_failures do
        expect { subject }.to raise_error(ArgumentError, /at least one column/)
        expect(first.reload.name).to eq('John')
      end

      it 'raises the same error from #sql' do
        expect { builder.sql }.to raise_error(ArgumentError, /at least one column/)
      end
    end
  end

  context 'with condition:' do
    let(:options) { { condition: condition } }
    # Evaluated against the pre-update row, so 'John' still matches while 'Jane' does not.
    let(:condition) { "t.\"name\" = 'John'" }

    it 'ANDs the parenthesized condition onto the key match' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "name" = v."name", "department_id" = v."department_id" ' \
        'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
        'WHERE t."id" = v."id" AND (t."name" = \'John\')'
      )
    end

    it 'updates only the rows that also satisfy the condition', :aggregate_failures do
      expect(subject).to eq(1)
      expect(first.reload).to have_attributes(name: 'John Updated', department_id: other_dep.id)
      expect(second.reload).to have_attributes(name: 'Jane', department_id: dep.id)
    end

    context 'when the condition compares against the incoming values' do
      let(:condition) { 't."department_id" <> v."department_id"' }

      it 'may reference both the target and the unnest alias' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "name" = v."name", "department_id" = v."department_id" ' \
          'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
          'WHERE t."id" = v."id" AND (t."department_id" <> v."department_id")'
        )
      end

      it 'skips rows whose value already equals the incoming one', :aggregate_failures do
        first.update_column(:department_id, other_dep.id)
        expect(subject).to eq(1)
        expect(first.reload.name).to eq('John')
        expect(second.reload.name).to eq('Jane Updated')
      end
    end

    context 'when a top-level OR is used' do
      let(:condition) { "t.\"name\" = 'John' OR TRUE" }

      it 'parenthesizes the condition so the OR cannot widen the key match' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "name" = v."name", "department_id" = v."department_id" ' \
          'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
          'WHERE t."id" = v."id" AND (t."name" = \'John\' OR TRUE)'
        )
      end

      it 'still touches no row outside attrs_list' do
        expect { subject }.not_to(change { bystander.reload.attributes })
      end
    end

    context 'when no row satisfies the condition' do
      let(:condition) { 'FALSE' }

      it 'builds the statement all the same' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "name" = v."name", "department_id" = v."department_id" ' \
          'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
          'WHERE t."id" = v."id" AND (FALSE)'
        )
      end

      it 'updates nothing and returns zero' do
        expect { expect(subject).to eq(0) }.not_to(change { first.reload.attributes })
      end
    end

    context 'with returning:' do
      let(:options) { { condition: "t.\"name\" = 'John'", returning: %i[id name] } }

      it 'places the condition before the RETURNING clause' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "name" = v."name", "department_id" = v."department_id" ' \
          'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
          'WHERE t."id" = v."id" AND (t."name" = \'John\') ' \
          'RETURNING t."id", t."name"'
        )
      end

      it 'returns only the rows the condition let through' do
        expect(subject).to contain_exactly({ id: first.id, name: 'John Updated' })
      end
    end

    context 'when condition is blank' do
      let(:condition) { '  ' }

      it 'raises ArgumentError before touching the database', :aggregate_failures do
        expect { subject }.to raise_error(ArgumentError, /condition must not be blank/)
        expect(first.reload.name).to eq('John')
      end

      # Never hand back `... AND (  )`, which PostgreSQL would reject as a syntax error.
      it 'raises the same error from #sql' do
        expect { builder.sql }.to raise_error(ArgumentError, /condition must not be blank/)
      end
    end
  end

  context 'with set_override:' do
    let(:options) { { set_override: set_override } }
    # Keeps the stored name unless the row is still 'John' — the other columns are unaffected.
    let(:set_override) { { name: 'CASE WHEN t."name" = \'John\' THEN v."name" ELSE t."name" END' } }

    it 'replaces that column assignment, in its payload position' do
      expect(builder.sql).to eq(
        'UPDATE "employees" AS t SET "name" = CASE WHEN t."name" = \'John\' THEN v."name" ELSE t."name" END, "department_id" = v."department_id" ' \
        'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
        'WHERE t."id" = v."id"'
      )
    end

    it 'still matches every row, writing the override result', :aggregate_failures do
      expect(subject).to eq(2)
      expect(first.reload).to have_attributes(name: 'John Updated', department_id: other_dep.id)
      # 'Jane' fails the CASE, so its name is left as-is — but department_id is still written.
      expect(second.reload).to have_attributes(name: 'Jane', department_id: other_dep.id)
    end

    context 'when the override names a column absent from attrs_list' do
      let(:set_override) { { shift_start: "TIME '08:30:00'" } }

      it 'appends an assignment for it after the payload columns' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "name" = v."name", "department_id" = v."department_id", "shift_start" = TIME \'08:30:00\' ' \
          'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
          'WHERE t."id" = v."id"'
        )
      end

      it 'writes the expression to that column too', :aggregate_failures do
        expect(subject).to eq(2)
        expect(first.reload).to have_attributes(name: 'John Updated', shift_start: Time.utc(2000, 1, 1, 8, 30))
        expect(second.reload.shift_start).to eq(Time.utc(2000, 1, 1, 8, 30))
      end
    end

    context 'when the override keys are Strings' do
      let(:set_override) { { 'name' => 'upper(v."name")' } }

      it 'treats them the same as Symbol keys' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "name" = upper(v."name"), "department_id" = v."department_id" ' \
          'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
          'WHERE t."id" = v."id"'
        )
      end

      it 'applies the override' do
        subject
        expect(first.reload.name).to eq('JOHN UPDATED')
      end
    end

    context 'when rows carry only the unique_by column' do
      let(:attrs_list) { [{ id: first.id }, { id: second.id }] }
      let(:set_override) { { name: "'Overridden'" } }

      it 'builds the SET clause entirely from the overrides' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "name" = \'Overridden\' ' \
          'FROM unnest(?::bigint[]) AS v("id") ' \
          'WHERE t."id" = v."id"'
        )
      end

      it 'updates the matched rows instead of raising', :aggregate_failures do
        expect(subject).to eq(2)
        expect(first.reload.name).to eq('Overridden')
        expect(second.reload.name).to eq('Overridden')
        expect(bystander.reload.name).to eq('Jake')
      end
    end

    context 'with condition: and returning:' do
      let(:options) do
        {
          condition: 't."department_id" = v."department_id"',
          set_override: { name: 'upper(v."name")' },
          returning: %i[id name]
        }
      end

      it 'combines the override, the condition and the projection' do
        expect(builder.sql).to eq(
          'UPDATE "employees" AS t SET "name" = upper(v."name"), "department_id" = v."department_id" ' \
          'FROM unnest(?::bigint[], ?::character varying[], ?::integer[]) AS v("id", "name", "department_id") ' \
          'WHERE t."id" = v."id" AND (t."department_id" = v."department_id") ' \
          'RETURNING t."id", t."name"'
        )
      end

      it 'returns the overridden values of the rows the condition let through' do
        first.update_column(:department_id, other_dep.id)
        expect(subject).to contain_exactly({ id: first.id, name: 'JOHN UPDATED' })
      end
    end

    context 'when the override names an unknown column' do
      let(:set_override) { { bogus_column: '1' } }

      it 'raises ArgumentError before touching the database', :aggregate_failures do
        expect { subject }.to raise_error(ArgumentError, /unknown.*set_override columns: bogus_column/)
        expect(first.reload.name).to eq('John')
      end

      it 'raises the same error from #sql' do
        expect { builder.sql }.to raise_error(ArgumentError, /unknown.*set_override columns: bogus_column/)
      end
    end

    context 'when the override names a unique_by column' do
      let(:set_override) { { id: '1' } }

      it 'raises ArgumentError before touching the database', :aggregate_failures do
        expect { subject }.to raise_error(ArgumentError, /must not override unique_by/)
        expect(first.reload.name).to eq('John')
      end

      it 'raises the same error from #sql' do
        expect { builder.sql }.to raise_error(ArgumentError, /must not override unique_by/)
      end
    end

    # `unique_by` is symbolized on the way in, so a String key names the very same column and
    # must be caught by the same guard — otherwise the override would rewrite the match column.
    context 'when the override names a unique_by column given as a String' do
      let(:options) { { unique_by: 'id', set_override: set_override } }
      let(:set_override) { { id: '1' } }

      it 'raises ArgumentError before touching the database', :aggregate_failures do
        expect { subject }.to raise_error(ArgumentError, /must not override unique_by/)
        expect(first.reload.name).to eq('John')
      end

      it 'raises the same error from #sql' do
        expect { builder.sql }.to raise_error(ArgumentError, /must not override unique_by/)
      end
    end

    context 'when an override expression is blank' do
      let(:set_override) { { name: '  ' } }

      it 'raises ArgumentError before touching the database', :aggregate_failures do
        expect { subject }.to raise_error(ArgumentError, /expressions must not be blank/)
        expect(first.reload.name).to eq('John')
      end

      it 'raises the same error from #sql' do
        expect { builder.sql }.to raise_error(ArgumentError, /expressions must not be blank/)
      end
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
