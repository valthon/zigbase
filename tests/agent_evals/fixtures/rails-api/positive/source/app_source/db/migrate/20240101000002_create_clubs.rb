class CreateClubs < ActiveRecord::Migration[8.1]
  def change
    create_table :clubs do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.references :owner, null: false, foreign_key: { to_table: :users }
      # String-backed enum (see Club#visibility) -- deliberately a different
      # backing type from User#role so a converter must handle both.
      t.string :visibility, null: false, default: "public_club"
      # Maintained by a raw SQLite trigger, NOT by Rails counter_cache.
      t.integer :posts_count, null: false, default: 0
      t.datetime :archived_at

      t.timestamps
    end

    add_index :clubs, :slug, unique: true
    add_index :clubs, :archived_at
  end
end
