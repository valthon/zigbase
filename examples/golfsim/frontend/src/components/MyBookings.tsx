import { useEffect, useState } from 'react';
import {
  myBookings, cancelBooking,
  subscribeBookings, token,
  type Booking, type RealtimeEvent,
} from '../lib/api';
import Auth from './Auth';

// ---------------------------------------------------------------------------
// BookingCard — a single booking with action buttons.
// ---------------------------------------------------------------------------
function BookingCard({ booking, onReload }: { booking: Booking; onReload: () => void }) {
  const [err, setErr] = useState<string | null>(null);

  async function cancel() {
    setErr(null);
    try { await cancelBooking(booking.id); onReload(); }
    catch (e: unknown) { setErr(e instanceof Error ? e.message : String(e)); }
  }

  return (
    <article className="card">
      <h2>{booking.expand?.listing?.title ?? booking.listing}</h2>
      <p className="muted">
        {new Date(booking.starts_at).toLocaleString()} → {new Date(booking.ends_at).toLocaleString()}
        {' '}· ${booking.price_total.toFixed(2)} · <strong>{booking.status}</strong>
      </p>
      <div style={{ display: 'flex', gap: '0.5rem', flexWrap: 'wrap' }}>
        {/* Cancel: available for pending or confirmed bookings */}
        {(booking.status === 'pending' || booking.status === 'confirmed') && (
          <button
            onClick={cancel}
            style={{ background: '#c0392b' }}
          >
            Cancel booking
          </button>
        )}
      </div>
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
        <p style={{ color: 'var(--accent)', fontSize: '0.85rem', marginBottom: '0.5rem' }}>
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
