class ApplicationController < ActionController::API
  # Every error leaves the app in the SAME custom envelope shape:
  #   { "error": { "code": ..., "message": ..., "details": { ... } } }
  # It is deliberately NOT ZigBase's error shape.
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid
  rescue_from ActionController::ParameterMissing, with: :render_parameter_missing

  private

  # --- authentication -------------------------------------------------

  def authenticate!
    return if current_user

    render_error(:unauthorized, "unauthorized", "A valid bearer token is required.")
  end

  def current_user
    return @current_user if defined?(@current_user)

    header = request.headers["Authorization"].to_s
    token = header.start_with?("Bearer ") ? header.delete_prefix("Bearer ") : nil
    @current_user = AuthToken.resolve(token)
  end

  # --- error envelope -------------------------------------------------

  def render_error(status, code, message, details = {})
    render status: status, json: {
      error: { code: code, message: message, details: details }
    }
  end

  def render_not_found(exception = nil)
    model = exception.respond_to?(:model) ? exception.model : nil
    render_error(:not_found, "not_found", "Resource not found.", model ? { "model" => [ model ] } : {})
  end

  def render_record_invalid(exception)
    render_error(:unprocessable_content, "validation_failed",
                 "The submitted record is invalid.",
                 exception.record.errors.to_hash.transform_keys(&:to_s))
  end

  def render_parameter_missing(exception)
    render_error(:bad_request, "parameter_missing",
                 "A required parameter is missing.",
                 { exception.param.to_s => [ "is required" ] })
  end

  def render_invalid_record(record)
    render_error(:unprocessable_content, "validation_failed",
                 "The submitted record is invalid.",
                 record.errors.to_hash.transform_keys(&:to_s))
  end

  # --- pagination envelope --------------------------------------------
  #
  # { "data": [...], "meta": { "page": N, "per_page": N, "total": N } }

  def paginated(relation, serializer)
    page = [ params.fetch(:page, 1).to_i, 1 ].max
    per_page = params.fetch(:per_page, 25).to_i.clamp(1, 100)
    total = relation.count

    records = relation.limit(per_page).offset((page - 1) * per_page)

    {
      data: records.map { |record| serializer.call(record) },
      meta: { page: page, per_page: per_page, total: total }
    }
  end
end
