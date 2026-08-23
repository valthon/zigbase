class Flag < ApplicationRecord
  # TRAP: `flaggable` is polymorphic. `flaggable_type` stores a Ruby class
  # name ("Post", "Comment"), so this one table references rows in several
  # tables with no foreign key and no single target collection.
  belongs_to :flaggable, polymorphic: true
  belongs_to :reporter, class_name: "User", inverse_of: :reported_flags

  validates :reason, presence: true, length: { maximum: 200 }
  validates :flaggable_type, inclusion: { in: %w[Post Comment] }
end
