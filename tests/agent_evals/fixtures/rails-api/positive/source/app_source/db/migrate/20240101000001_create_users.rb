class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :display_name, null: false
      # Active Record `encrypts :phone` stores a JSON envelope, so the column
      # must be wide/free-form even though the plaintext is a short string.
      t.text :phone
      # Integer-backed enum (see User#role).
      t.integer :role, null: false, default: 0

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :role
  end
end
