class Club < ApplicationRecord
  # TRAP: an unqualified `Club.all` / `Club.find_by` silently excludes archived
  # clubs. Only `Club.unscoped` sees the whole table. Any tool that reads
  # through the models rather than through SQL will lose rows here.
  default_scope { where(archived_at: nil) }

  enum :visibility, { public_club: "public_club", private_club: "private_club" }, validate: true

  belongs_to :owner, class_name: "User", inverse_of: :owned_clubs

  has_many :memberships, dependent: :destroy
  has_many :members, through: :memberships, source: :user
  has_many :posts, dependent: :destroy
  has_many :events, dependent: :destroy

  validates :name, presence: true, length: { maximum: 80 }
  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, message: "must be lowercase dash-case" }

  def to_param = slug

  def member?(user)
    return false if user.nil?
    return true if user.id == owner_id

    memberships.exists?(user_id: user.id)
  end

  def readable_by?(user)
    public_club? || member?(user)
  end
end
