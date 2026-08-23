class ReadingEvent < Event
  validates :pages_target, presence: true, numericality: { only_integer: true, greater_than: 0 }
end
