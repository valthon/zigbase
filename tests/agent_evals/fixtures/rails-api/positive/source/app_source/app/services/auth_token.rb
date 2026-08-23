# Minimal, self-signed bearer token. This is API-only: there is no Rails
# session, no cookie, and no Devise/JWT gem -- just an HMAC over the user id
# keyed by `secret_key_base`.
#
#   token = "<user_id>.<hex hmac-sha256 of user_id>"
module AuthToken
  module_function

  def issue(user)
    "#{user.id}.#{signature(user.id)}"
  end

  # Returns the User, or nil when the token is missing/garbled/forged.
  def resolve(token)
    return nil if token.blank?

    id, sig = token.split(".", 2)
    return nil if id.blank? || sig.blank?
    return nil unless ActiveSupport::SecurityUtils.secure_compare(sig, signature(id))

    User.find_by(id: id)
  end

  def signature(user_id)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "bookclub-token:#{user_id}")
  end
end
