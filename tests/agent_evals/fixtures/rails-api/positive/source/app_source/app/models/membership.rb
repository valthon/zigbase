class Membership < ApplicationRecord
  enum :role, { reader: 0, curator: 1 }, validate: true

  belongs_to :user
  belongs_to :club

  validates :joined_at, presence: true
  validates :user_id, uniqueness: { scope: :club_id, message: "is already a member of this club" }
end
