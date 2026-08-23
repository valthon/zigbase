class Post < ApplicationRecord
  enum :status, { draft: "draft", published: "published", archived: "archived" }, validate: true

  belongs_to :club
  belongs_to :author, class_name: "User", inverse_of: :posts

  has_many :comments, dependent: :destroy
  has_many :flags, as: :flaggable, dependent: :destroy

  has_one_attached :cover

  validates :title, presence: true, length: { minimum: 3, maximum: 120 }
  validates :body, presence: true, if: :published?
end
