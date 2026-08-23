class MeetingEvent < Event
  validates :location, presence: true
end
