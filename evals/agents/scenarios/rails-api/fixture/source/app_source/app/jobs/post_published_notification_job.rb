class PostPublishedNotificationJob < ApplicationJob
  queue_as :notifications

  # Writes one `notifications` row per club member (and the owner), excluding
  # the author. This is the observable side effect of `PATCH .../publish`.
  def perform(post_id)
    post = Post.find_by(id: post_id)
    return if post.nil?

    club = Club.unscoped.find_by(id: post.club_id)
    return if club.nil?

    recipient_ids = (club.memberships.pluck(:user_id) + [ club.owner_id ]).uniq
    recipient_ids -= [ post.author_id ]

    recipient_ids.sort.each do |user_id|
      Notification.create!(
        user_id: user_id,
        kind: "post.published",
        payload: { "post_id" => post.id, "club_id" => club.id, "title" => post.title },
        created_at: Time.current
      )
    end
  end
end
