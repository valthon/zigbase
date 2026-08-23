module Api
  module V1
    class SessionsController < BaseController
      skip_before_action :authenticate!, only: [ :create ]

      def create
        user = User.find_by(email: params[:email].to_s.strip.downcase)

        # `authenticate` is has_secure_password/bcrypt.
        if user&.authenticate(params[:password].to_s)
          render status: :created, json: {
            data: {
              token: AuthToken.issue(user),
              user: { id: user.id, email: user.email, display_name: user.display_name, role: user.role }
            }
          }
        else
          render_error(:unauthorized, "invalid_credentials", "Email or password is incorrect.")
        end
      end
    end
  end
end
