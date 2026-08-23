class CreatePosts < ActiveRecord::Migration[8.1]
  def change
    create_table :posts do |t|
      t.references :club, null: false, foreign_key: true
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.text :body
      t.string :status, null: false, default: "draft"
      t.datetime :published_at

      t.timestamps
    end

    add_index :posts, [ :club_id, :status ]
    add_index :posts, :published_at
  end
end
