class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    # `created_at` only -- no `updated_at`. Notifications are append-only, and
    # the missing half of `t.timestamps` is itself a trait a converter must
    # not paper over.
    create_table :notifications do |t|
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false
      # JSON payload stored in a text column and declared `serialize ... JSON`
      # on the model (see Notification).
      t.text :payload, null: false, default: "{}"

      t.datetime :created_at, null: false
    end

    add_index :notifications, [ :user_id, :kind ]
  end
end
