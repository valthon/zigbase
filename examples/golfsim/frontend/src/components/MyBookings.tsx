import { useEffect, useState } from 'react';
import { myBookings, confirmBooking, token, type Booking } from '../lib/api';
import Auth from './Auth';

export default function MyBookings() {
  const [authed, setAuthed] = useState(() => token() !== null);
  const [bookings, setBookings] = useState<Booking[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  function reload() {
    myBookings().then(setBookings).catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
  }
  useEffect(() => {
    if (authed) reload();
  }, [authed]);

  if (!authed) return <Auth onAuthed={() => setAuthed(true)} />;
  if (error) return <p className="error">{error}</p>;
  if (!bookings) return <p className="muted">Loading…</p>;
  if (bookings.length === 0) return <p className="muted">No bookings yet — <a href="/">browse listings</a>.</p>;
  return (
    <>
      {bookings.map((b) => (
        <article className="card" key={b.id}>
          <h2>{b.expand?.listing?.title ?? b.listing}</h2>
          <p className="muted">
            {new Date(b.starts_at).toLocaleString()} → {new Date(b.ends_at).toLocaleString()} ·
            ${b.price_total.toFixed(2)} · <strong>{b.status}</strong>
          </p>
          {b.status === 'pending' && (
            /* Demo simplification: the /confirm route accepts any authed caller, so the
               guest confirms their own hold here. A real app would restrict confirmation
               to the simulator owner — see main.zig's NOTE. */
            <button onClick={() => confirmBooking(b.id).then(reload).catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)))}>
              Confirm (custom route)
            </button>
          )}
        </article>
      ))}
    </>
  );
}
