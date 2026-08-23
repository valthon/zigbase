class User < ApplicationRecord
  has_secure_password

  # Active Record encryption. `deterministic: true` so the ciphertext is a
  # pure function of (plaintext, key set) and the frozen fixture database is
  # byte-reproducible. Non-deterministic encryption (the default) would use a
  # random IV per write and re-seeding would produce a different file.
  encrypts :phone, deterministic: true

  enum :role, { member: 0, moderator: 1, admin: 2 }, validate: true

  has_many :memberships, dependent: :destroy
  has_many :clubs, through: :memberships
  has_many :owned_clubs, class_name: "Club", foreign_key: :owner_id, inverse_of: :owner, dependent: :restrict_with_exception
  has_many :posts, class_name: "Post", foreign_key: :author_id, inverse_of: :author, dependent: :destroy
  has_many :comments, class_name: "Comment", foreign_key: :author_id, inverse_of: :author, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :reported_flags, class_name: "Flag", foreign_key: :reporter_id, inverse_of: :reporter, dependent: :destroy

  validates :email, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/, message: "must be a valid email address" }
  validates :display_name, presence: true, length: { minimum: 2, maximum: 40 }

  normalizes :email, with: ->(value) { value.to_s.strip.downcase }
end
