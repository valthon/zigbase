module Api
  module V1
    class StatsController < BaseController
      skip_before_action :authenticate!

      # GET /api/v1/internal/stats(.json)
      #
      # Reached through a bare `scope` carrying `defaults: { internal: "true" }`
      # and a `format` constraint, so the route dump for this app is not a
      # plain list of RESTful resources.
      def show
        render json: {
          data: {
            internal: params[:internal],
            format: request.format.to_s,
            # `Club.count` obeys the default_scope; `Club.unscoped.count` does not.
            clubs_visible: Club.count,
            clubs_total: Club.unscoped.count,
            posts_total: Post.count,
            users_total: User.count
          },
          meta: { page: 1, per_page: 1, total: 1 }
        }
      end
    end
  end
end
