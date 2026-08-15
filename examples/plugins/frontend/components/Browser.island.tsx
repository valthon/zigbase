import { useEffect, useState } from "@z/runtime";
import {
  listAuthors,
  listPosts,
  listComments,
  getMe,
  initiateLogin,
  createComment,
  type Author,
  type Post,
  type Comment,
  type Commenter,
} from "../src/lib/api";

export interface Props {}

export default function Browser(_: Props) {
  const [authors, setAuthors] = useState<Author[] | null>(null);
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [comments, setComments] = useState<Comment[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Login state for the commenters magic-link flow.
  const [me, setMe] = useState<Commenter | null | "loading">("loading");
  const [loginEmail, setLoginEmail] = useState("");
  const [loginState, setLoginState] = useState<"idle" | "sent" | "error">("idle");

  // Comment submission state.
  const [commentBody, setCommentBody] = useState("");
  const [commentPost, setCommentPost] = useState("");
  const [submitState, setSubmitState] = useState<"idle" | "ok" | "error">("idle");
  const [submitError, setSubmitError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([listAuthors(), listPosts(), listComments()])
      .then(([nextAuthors, nextPosts, nextComments]) => {
        setAuthors(nextAuthors);
        setPosts(nextPosts);
        setComments(nextComments);
      })
      .catch((cause) => setError(cause instanceof Error ? cause.message : String(cause)));

    // Check if a commenter session is active (cookie-based).
    getMe().then(setMe).catch(() => setMe(null));
  }, []);

  if (error) return <p class="error" role="alert">{error}</p>;
  if (!authors || !posts || !comments) return <p class="muted" aria-live="polite">Loading&hellip;</p>;

  return (
    <>
      <section class="card" aria-labelledby="authors-heading">
        <h2 id="authors-heading">Authors ({authors.length})</h2>
        {/* Authors is an auth collection using WebAuthn and api_token. The
            passkey ceremony is documented in examples/plugins/README.md. */}
        {authors.length === 0
          ? <p class="muted">None yet &mdash; add some via the <a href="/_/">admin UI</a>.</p>
          : <ul>{authors.map((author) => <li key={author.id}>{author.name}{author.bio ? <span class="muted"> &mdash; {author.bio}</span> : null}</li>)}</ul>}
      </section>

      <section class="card" aria-labelledby="posts-heading">
        <h2 id="posts-heading">Published posts ({posts.length})</h2>
        {posts.length === 0
          ? <p class="muted">None yet &mdash; only posts with status &ldquo;published&rdquo; appear here (the comptime list rule).</p>
          : <ul>{posts.map((post) => <li key={post.id}>{post.title} <span class="muted">by {post.expand?.author?.name ?? "?"}</span></li>)}</ul>}
      </section>

      <section class="card" aria-labelledby="comments-heading">
        <h2 id="comments-heading">Approved comments ({comments.length})</h2>
        {comments.length === 0
          ? <p class="muted">None yet &mdash; only comments with <code>approved=true</code> appear here.</p>
          : <ul>{comments.map((comment) => (
              <li key={comment.id}>
                <span class="muted">{comment.expand?.commenter?.display_name ?? "anonymous"}: </span>
                {comment.body}
              </li>
            ))}</ul>}

        <h3>Add a comment</h3>
        {me === "loading" ? (
          <p class="muted" aria-live="polite">Checking login&hellip;</p>
        ) : me === null ? (
          loginState === "sent" ? (
            <p class="muted" role="status">
              Check your email for a login link. In local development, look in the server log for the magic-link token.
            </p>
          ) : (
            <form onSubmit={async (event) => {
              event.preventDefault();
              try {
                await initiateLogin(loginEmail);
                setLoginState("sent");
              } catch {
                setLoginState("error");
              }
            }}>
              <label for="commenter-email">Email address</label>
              <input
                id="commenter-email"
                type="email"
                autocomplete="email"
                placeholder="your@email.com"
                value={loginEmail}
                onInput={(event) => setLoginEmail(event.currentTarget.value)}
                required
              />
              <button type="submit">Send login link</button>
              {loginState === "error" && <p class="error" role="alert">Login failed. Try again.</p>}
            </form>
          )
        ) : submitState === "ok" ? (
          <p class="muted" role="status">Comment submitted &mdash; pending approval.</p>
        ) : (
          <form onSubmit={async (event) => {
            event.preventDefault();
            try {
              await createComment(commentPost, commentBody);
              setSubmitState("ok");
              setCommentBody("");
            } catch (cause) {
              setSubmitState("error");
              setSubmitError(cause instanceof Error ? cause.message : String(cause));
            }
          }}>
            <label for="comment-post">Post</label>
            <select id="comment-post" value={commentPost} onInput={(event) => setCommentPost(event.currentTarget.value)} required>
              <option value="">Select a post&hellip;</option>
              {posts.map((post) => <option key={post.id} value={post.id}>{post.title}</option>)}
            </select>
            <label for="comment-body">Comment</label>
            <textarea
              id="comment-body"
              placeholder="Your comment&hellip;"
              value={commentBody}
              onInput={(event) => setCommentBody(event.currentTarget.value)}
              required
            />
            <button type="submit">Submit</button>
            {submitState === "error" && <p class="error" role="alert">{submitError}</p>}
          </form>
        )}
      </section>
    </>
  );
}
