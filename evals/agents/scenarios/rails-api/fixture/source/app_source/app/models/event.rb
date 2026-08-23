# Single Table Inheritance base class. `Event.all` returns a mix of concrete
# subclasses, discriminated by the `type` column.
class Event < ApplicationRecord
  self.inheritance_column = "type"

  belongs_to :club

  validates :title, presence: true, length: { maximum: 120 }
  validates :starts_at, presence: true
end
