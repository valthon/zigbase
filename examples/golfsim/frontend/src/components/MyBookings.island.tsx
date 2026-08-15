import { useEffect, useState } from '@z/runtime';
import {
  myBookings, cancelBooking, createReview,
  subscribeBookings, token,
  type Booking, type RealtimeEvent,
} from '../lib/api';
import Auth from './Auth';

// ---------------------------------------------------------------------------
// ReviewForm — leave a rating + note for a CONFIRMED booking. The backend's
// prepareReview hook re-checks ownership + confirmed status, so this is a
// convenience UI, not the source of truth.
// ---------------------------------------------------------------------------
function ReviewForm({ bookingId, onDone }: { bookingId: string; onDone: () => void }) {
  const [rating, setRating] = useState(5);
  const [body, setBody] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  async function submit() {
    setErr(null);
    try {
      await createReview(bookingId, rating, body);
      setDone(true);
      onDone();
    } catch (e: unknown) {
      setErr(e instanceof Error ? e.message : String(e));
    }
  }

  if (done) return <p className="muted" style={{ fontSize: '0.85rem' }}>Review submitted. Thanks!</p>;
  return (
    <div style={{ marginTop: '0.5rem', display: 'flex', flexDirection: 'column', gap: '0.4rem' }}>
      <label style={{ fontSize: '0.85rem' }}>
        Rating:{' '}
        <select value={rating} onChange={(e) => setRating(Number(e.currentTarget.value))}>
          {[5, 4, 3, 2, 1].map((n) => <option key={n} value={n}>{n} ★</option>)}
        </select>
      </label>
      <textarea
        placeholder="How was your session?"
        value={body}
        onChange={(e) => setBody(e.currentTarget.value)}
        rows={2}
        style={{ width: '100%' }}
      />
      <button onClick={submit}>Submit review</button>
      {err && <p className="error">{err}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------
// BookingCard — a single booking with action buttons.
// ---------------------------------------------------------------------------
function BookingCard({ booking, onReload }: { booking: Booking; onReload: () => void }) {
  const [err, setErr] = useState<string | null>(null);
  const [showReview, setShowReview] = useState(false);

  async function cancel() {
    setErr(null);
    try { await cancelBooking(booking.id); onReload(); }
    catch (e: unknown) { setErr(e instanceof Error ? e.message : String(e)); }
  }

  return (
    <article className="card">
      <h2>{booking.expand?.listing?.title ?? booking.listing}</h2>
      <p className="muted">
        <span className="num">{new Date(booking.starts_at).toLocaleString()}</span> →{' '}
        <span className="num">{new Date(booking.ends_at).toLocaleString()}</span>
        {' '}· <span className="price">${booking.price_total?.toFixed(2) ?? '0.00'}</span> · <strong>{booking.status}</strong>
      </p>
      <div style={{ display: 'flex', gap: '0.5rem', flexWrap: 'wrap' }}>
        {/* Cancel: available for pending or confirmed bookings */}
        {(booking.status === 'pending' || booking.status === 'confirmed') && (
          <button
            onClick={cancel}
            style={{ background: 'var(--danger)', borderColor: 'var(--danger)' }}
          >
            Cancel booking
          </button>
        )}
        {/* Review: only for confirmed bookings (the backend enforces this too) */}
        {booking.status === 'confirmed' && !showReview && (
          <button onClick={() => setShowReview(true)}>Leave a review</button>
        )}
      </div>
      {showReview && (
        <ReviewForm bookingId={booking.id} onDone={() => setShowReview(false)} />
      )}
      {err && <p className="error">{err}</p>}
    </article>
  );
}

// ---------------------------------------------------------------------------
// MyBookings — the main /bookings page component.
//
// Subscribes to the bookings realtime topic so the list live-updates when a
// host confirms (or when the cron cancels a stale hold) — no polling needed.
// ---------------------------------------------------------------------------
export default function MyBookings() {
  const [authed, setAuthed] = useState(() => token() !== null);
  const [bookings, setBookings] = useState<Booking[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [realtimeBadge, setRealtimeBadge] = useState(false);

  function reload() {
    myBookings()
      .then(setBookings)
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
  }

  useEffect(() => {
    if (!authed) return;
    reload();

    // Subscribe to realtime booking events.  When any booking changes (host
    // confirms, cron cancels, etc.) we reload the full list so the UI stays
    // consistent.  The badge flashes briefly to signal the update.
    const unsub = subscribeBookings((_ev: RealtimeEvent) => {
      reload();
      setRealtimeBadge(true);
      setTimeout(() => setRealtimeBadge(false), 2000);
    });
    return unsub;
  }, [authed]);

  if (!authed) return <Auth onAuthed={() => setAuthed(true)} />;
  if (error) return <p className="error">{error}</p>;
  if (!bookings) return <p className="muted">Loading…</p>;
  return (
    <>
      {realtimeBadge && (
        <p style={{ color: 'var(--grass)', fontSize: '0.85rem', marginBottom: '0.5rem', fontWeight: 600 }}>
          ↻ Booking updated via realtime
        </p>
      )}
      {bookings.length === 0 && (
        <p className="muted">No bookings yet — <a href="/">browse listings</a>.</p>
      )}
      {bookings.map((b) => (
        <BookingCard key={b.id} booking={b} onReload={reload} />
      ))}
    </>
  );
}
