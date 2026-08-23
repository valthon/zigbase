class CreateFlags < ActiveRecord::Migration[8.1]
  def change
    # Polymorphic association: `flaggable_type` names the *Ruby class*, so a
    # single table points at rows in several different tables. There is no
    # foreign key and no single-collection mapping.
    create_table :flags do |t|
      t.string :flaggable_type, null: false
      t.bigint :flaggable_id, null: false
      t.references :reporter, null: false, foreign_key: { to_table: :users }
      t.string :reason, null: false

      t.timestamps
    end

    add_index :flags, [ :flaggable_type, :flaggable_id ]
  end
end
