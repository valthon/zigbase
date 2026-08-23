module Api
  module V1
    class PostsController < BaseController
      # `show_cover` is public in the same sense `show` is: readability is
      # decided per club by `Club#readable_by?`, not by the presence of a token.
      skip_before_action :authenticate!, only: [ :index, :show, :show_cover ]

      # GET /api/v1/clubs/:club_slug/posts
      def index
        club = find_club!

        # PARITY TRAP: a private club is 404 (not 403) to a non-member, so an
        # outsider cannot even learn the club exists.
        return render_not_found unless club.readable_by?(current_user)

        render json: paginated(club.posts.order(:id), method(:serialize))
      end

      # GET /api/v1/posts/:id
      def show
        post = Post.find(params[:id])
        return render_not_found unless post.club.readable_by?(current_user)

        render json: { data: serialize(post) }
      end

      # POST /api/v1/clubs/:club_slug/posts
      def create
        club = find_club!
        return render_not_found unless club.readable_by?(current_user)

        post = club.posts.new(post_params.merge(author: current_user))

        if post.save
          render status: :created, json: { data: serialize(post) }
        else
          render_invalid_record(post)
        end
      end

      # PATCH /api/v1/posts/:id/publish -- author only.
      def publish
        post = Post.find(params[:id])
        return render_error(:forbidden, "forbidden", "Only the post author may publish this post.") unless post.author_id == current_user.id

        post.status = "published"
        post.published_at = Time.current

        return render_invalid_record(post) unless post.save

        # With the :inline adapter this runs synchronously, so the
        # notifications rows exist before the response is written.
        PostPublishedNotificationJob.perform_later(post.id)

        render json: { data: serialize(post) }
      end

      # POST /api/v1/posts/:id/cover -- multipart/form-data.
      def upload_cover
        post = Post.find(params[:id])
        return render_error(:forbidden, "forbidden", "Only the post author may attach a cover.") unless post.author_id == current_user.id

        upload = params[:cover]
        return render_error(:bad_request, "parameter_missing", "A required parameter is missing.", { "cover" => [ "is required" ] }) if upload.blank?

        post.cover.attach(upload)

        render status: :created, json: { data: cover_payload(post) }
      end

      # GET /api/v1/posts/:id/cover
      def show_cover
        post = Post.find(params[:id])
        return render_not_found unless post.club.readable_by?(current_user)
        return render_not_found unless post.cover.attached?

        send_data post.cover.download,
                  type: post.cover.content_type,
                  filename: post.cover.filename.to_s,
                  disposition: "inline"
      end

      private

      def post_params
        params.require(:post).permit(:title, :body, :status)
      end

      def cover_payload(post)
        return nil unless post.cover.attached?

        blob = post.cover.blob
        {
          attached: true,
          blob_id: blob.id,
          key: blob.key,
          filename: blob.filename.to_s,
          content_type: blob.content_type,
          byte_size: blob.byte_size,
          checksum: blob.checksum
        }
      end

      def serialize(post)
        {
          id: post.id,
          club_id: post.club_id,
          author_id: post.author_id,
          title: post.title,
          body: post.body,
          status: post.status,
          published_at: post.published_at&.utc&.iso8601,
          cover: cover_payload(post),
          created_at: post.created_at&.utc&.iso8601,
          updated_at: post.updated_at&.utc&.iso8601
        }
      end
    end
  end
end
