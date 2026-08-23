class Comment < ApplicationRecord
  belongs_to :post
  belongs_to :author, class_name: "User", inverse_of: :comments

  has_many :flags, as: :flaggable, dependent: :destroy

  validates :body, presence: true, length: { maximum: 2000 }
end
