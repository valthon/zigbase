class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    # Single Table Inheritance: `type` holds a Ruby class name and several
    # model classes share this one table.
    create_table :events do |t|
      t.string :type, null: false
      t.references :club, null: false, foreign_key: true
      t.string :title, null: false
      t.datetime :starts_at, null: false
      # Only meaningful for MeetingEvent.
      t.string :location
      # Only meaningful for ReadingEvent.
      t.integer :pages_target

      t.timestamps
    end

    add_index :events, :type
  end
end
