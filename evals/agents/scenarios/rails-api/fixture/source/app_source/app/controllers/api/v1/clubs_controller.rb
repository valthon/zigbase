module Api
  module V1
    class ClubsController < BaseController
      skip_before_action :authenticate!, only: [ :index, :show ]

      before_action :set_club, only: [ :show, :update ]

      # GET /api/v1/clubs
      def index
        # `Club.order(...)` runs through the default_scope: archived clubs are
        # silently absent from this list AND from `meta.total`.
        render json: paginated(Club.order(:id), method(:serialize))
      end

      # GET /api/v1/clubs/:slug
      def show
        render json: { data: serialize(@club) }
      end

      # PATCH /api/v1/clubs/:slug -- owner only.
      def update
        return render_error(:forbidden, "forbidden", "Only the club owner may update this club.") unless @club.owner_id == current_user.id

        if @club.update(club_params)
          render json: { data: serialize(@club) }
        else
          render_invalid_record(@club)
        end
      end

      private

      def set_club
        @club = find_club!
      end

      def club_params
        params.require(:club).permit(:name, :visibility)
      end

      def serialize(club)
        {
          id: club.id,
          name: club.name,
          slug: club.slug,
          owner_id: club.owner_id,
          visibility: club.visibility,
          posts_count: club.posts_count,
          archived_at: club.archived_at&.utc&.iso8601,
          created_at: club.created_at&.utc&.iso8601,
          updated_at: club.updated_at&.utc&.iso8601
        }
      end
    end
  end
end
