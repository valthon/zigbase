module Api
  module V1
    class BaseController < ApplicationController
      before_action :authenticate!

      private

      # `Club.find_by!` goes through the model's default_scope, so an ARCHIVED
      # club is a 404 here even though the row exists.
      def find_club!
        Club.find_by!(slug: params[:club_slug] || params[:slug])
      end
    end
  end
end
