class AddPostsCountTriggers < ActiveRecord::Migration[8.1]
  # Raw SQLite triggers maintain clubs.posts_count. This logic lives *in the
  # database*, not in Rails: it is invisible to `db/schema.rb` (the :ruby
  # schema format cannot express triggers) and it fires for writes that never
  # go through Active Record.
  def up
    execute <<~SQL
      CREATE TRIGGER posts_count_after_insert
      AFTER INSERT ON posts
      BEGIN
        UPDATE clubs SET posts_count = posts_count + 1 WHERE id = NEW.club_id;
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER posts_count_after_delete
      AFTER DELETE ON posts
      BEGIN
        UPDATE clubs SET posts_count = posts_count - 1 WHERE id = OLD.club_id;
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER posts_count_after_club_change
      AFTER UPDATE OF club_id ON posts
      WHEN OLD.club_id <> NEW.club_id
      BEGIN
        UPDATE clubs SET posts_count = posts_count - 1 WHERE id = OLD.club_id;
        UPDATE clubs SET posts_count = posts_count + 1 WHERE id = NEW.club_id;
      END;
    SQL

    # A database view, for the same reason: schema.rb will not carry it.
    execute <<~SQL
      CREATE VIEW published_post_counts AS
      SELECT club_id, COUNT(*) AS published_count
      FROM posts
      WHERE status = 'published'
      GROUP BY club_id;
    SQL
  end

  def down
    execute "DROP VIEW IF EXISTS published_post_counts;"
    execute "DROP TRIGGER IF EXISTS posts_count_after_club_change;"
    execute "DROP TRIGGER IF EXISTS posts_count_after_delete;"
    execute "DROP TRIGGER IF EXISTS posts_count_after_insert;"
  end
end
