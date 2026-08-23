module Api
  module V1
    class UsersController < BaseController
      # Signup is the one public write.
      skip_before_action :authenticate!, only: [ :create ]

      def create
        user = User.new(user_params)

        if user.save
          render status: :created, json: { data: serialize(user) }
        else
          render_invalid_record(user)
        end
      end

      private

      def user_params
        params.require(:user).permit(:email, :password, :display_name, :phone, :role)
      end

      def serialize(user)
        {
          id: user.id,
          email: user.email,
          display_name: user.display_name,
          role: user.role,
          phone: user.phone,
          created_at: user.created_at&.utc&.iso8601
        }
      end
    end
  end
end
