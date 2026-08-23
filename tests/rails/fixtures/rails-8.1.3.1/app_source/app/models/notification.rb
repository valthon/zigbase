class Notification < ApplicationRecord
  # `created_at` only; the table has no `updated_at` column.
  self.record_timestamps = false

  serialize :payload, coder: JSON, type: Hash

  belongs_to :user

  validates :kind, presence: true
end
