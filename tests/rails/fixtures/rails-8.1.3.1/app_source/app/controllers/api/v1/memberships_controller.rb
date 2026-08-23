module Api
  module V1
    class MembershipsController < BaseController
      # POST /api/v1/clubs/:club_slug/memberships
      def create
        club = find_club!
        membership = nil

        begin
          # Explicit multi-write transaction: the membership AND the owner's
          # notification either both land or neither does.
          ActiveRecord::Base.transaction do
            membership = Membership.create!(
              user: current_user,
              club: club,
              role: params.fetch(:role, "reader"),
              joined_at: Time.current
            )

            Notification.create!(
              user_id: club.owner_id,
              kind: "membership.created",
              payload: { "club_id" => club.id, "club_slug" => club.slug, "user_id" => current_user.id },
              created_at: Time.current
            )
          end
        rescue ActiveRecord::RecordInvalid => e
          # Re-raised as the custom envelope; the Notification insert above is
          # rolled back with it.
          return render_invalid_record(e.record)
        end

        render status: :created, json: {
          data: {
            id: membership.id,
            club_id: membership.club_id,
            user_id: membership.user_id,
            role: membership.role,
            joined_at: membership.joined_at.utc.iso8601
          }
        }
      end
    end
  end
end
