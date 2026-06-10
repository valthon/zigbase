import { useEffect, useState } from 'react';
import { listListings, createBooking, token, type Listing } from '../lib/api';
import Auth from './Auth';

function BookForm({ listing }: { listing: Listing }) {
  const [start, setStart] = useState('');
  const [end, setEnd] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [booked, setBooked] = useState<number | null>(null);

  async function book() {
    setBusy(true); setError(null);
    try {
      // datetime-local gives "YYYY-MM-DDTHH:MM" in the user's LOCAL time; appending
      // ":00Z" treats it as UTC — fine for a demo, wrong across timezones. Use a
      // timezone-aware conversion in a real app.
      const b = await createBooking(listing.id, `${start}:00Z`, `${end}:00Z`);
      setBooked(b.price_total);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  if (booked !== null)
    return <p>Booked! Total ${booked.toFixed(2)} — see <a href="/bookings">your bookings</a>.</p>;
  return (
    <div>
      <input type="datetime-local" value={start} onChange={(e) => setStart(e.target.value)} />
      <input type="datetime-local" value={end} onChange={(e) => setEnd(e.target.value)} />
      <button disabled={busy || !start || !end} onClick={book}>Hold this slot</button>
      {error && <p className="error">{error}</p>}
    </div>
  );
}

export default function ListingsBrowser() {
  const [authed, setAuthed] = useState(() => token() !== null);
  const [listings, setListings] = useState<Listing[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    listListings().then(setListings).catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
  }, []);

  if (error) return <p className="error">Failed to load listings: {error}</p>;
  if (!listings) return <p className="muted">Loading…</p>;
  return (
    <>
      {!authed && <Auth onAuthed={() => setAuthed(true)} />}
      {listings.length === 0 && (
        <p className="muted">
          No published listings yet — create a simulator + listing via the
          <a href="/_/" data-astro-reload> admin UI</a> or the API (see the README's seed script).
        </p>
      )}
      {listings.map((l) => (
        <article className="card" key={l.id}>
          <h2>{l.title}</h2>
          <p className="muted">
            {l.expand?.simulator?.label ?? 'simulator'} · ${l.price_per_hour}/hour
          </p>
          {authed ? <BookForm listing={l} /> : <p className="muted">Sign in above to book.</p>}
        </article>
      ))}
    </>
  );
}
