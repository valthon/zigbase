# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2024_01_01_000010) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "clubs", force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "owner_id", null: false
    t.integer "posts_count", default: 0, null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.string "visibility", default: "public_club", null: false
    t.index ["archived_at"], name: "index_clubs_on_archived_at"
    t.index ["owner_id"], name: "index_clubs_on_owner_id"
    t.index ["slug"], name: "index_clubs_on_slug", unique: true
  end

  create_table "comments", force: :cascade do |t|
    t.integer "author_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.integer "post_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_comments_on_author_id"
    t.index ["post_id"], name: "index_comments_on_post_id"
  end

  create_table "events", force: :cascade do |t|
    t.integer "club_id", null: false
    t.datetime "created_at", null: false
    t.string "location"
    t.integer "pages_target"
    t.datetime "starts_at", null: false
    t.string "title", null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["club_id"], name: "index_events_on_club_id"
    t.index ["type"], name: "index_events_on_type"
  end

  create_table "flags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "flaggable_id", null: false
    t.string "flaggable_type", null: false
    t.string "reason", null: false
    t.integer "reporter_id", null: false
    t.datetime "updated_at", null: false
    t.index ["flaggable_type", "flaggable_id"], name: "index_flags_on_flaggable_type_and_flaggable_id"
    t.index ["reporter_id"], name: "index_flags_on_reporter_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.integer "club_id", null: false
    t.datetime "created_at", null: false
    t.datetime "joined_at", null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["club_id"], name: "index_memberships_on_club_id"
    t.index ["user_id", "club_id"], name: "index_memberships_on_user_and_club", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.text "payload", default: "{}", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "kind"], name: "index_notifications_on_user_id_and_kind"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "posts", force: :cascade do |t|
    t.integer "author_id", null: false
    t.text "body"
    t.integer "club_id", null: false
    t.datetime "created_at", null: false
    t.datetime "published_at"
    t.string "status", default: "draft", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_posts_on_author_id"
    t.index ["club_id", "status"], name: "index_posts_on_club_id_and_status"
    t.index ["club_id"], name: "index_posts_on_club_id"
    t.index ["published_at"], name: "index_posts_on_published_at"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.text "phone"
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["role"], name: "index_users_on_role"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "clubs", "users", column: "owner_id"
  add_foreign_key "comments", "posts"
  add_foreign_key "comments", "users", column: "author_id"
  add_foreign_key "events", "clubs"
  add_foreign_key "flags", "users", column: "reporter_id"
  add_foreign_key "memberships", "clubs"
  add_foreign_key "memberships", "users"
  add_foreign_key "notifications", "users"
  add_foreign_key "posts", "clubs"
  add_foreign_key "posts", "users", column: "author_id"
end
