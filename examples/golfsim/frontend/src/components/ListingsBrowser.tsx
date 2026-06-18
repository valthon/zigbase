import { useEffect, useState } from 'react';
import {
  listListings, createBooking, getAvailability, uploadListingPhotos,
  photoUrl, token, type Listing, type AvailabilitySlot,
} from '../lib/api';
import Auth from './Auth';

// ---------------------------------------------------------------------------
// AvailabilityBadge — small indicator shown on each listing card when the
// user expands availability. Fetched lazily on first click.
// ---------------------------------------------------------------------------
function AvailabilityPanel({ listing }: { listing: Listing }) {
  const [slots, setSlots] = useState<AvailabilitySlot[] | null>(null);
  const [open, setOpen] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  function toggle() {
    if (!open && slots === null) {
      getAvailability(listing.id)
        .then(setSlots)
        .catch((e: unknown) => setErr(e instanceof Error ? e.message : String(e)));
    }
    setOpen((v) => !v);
  }

  return (
    <div style={{ marginBottom: '0.5rem' }}>
      <button
        onClick={toggle}
        style={{ background: 'transparent', color: 'var(--grass)', border: '1px solid var(--grass)', padding: '0.25rem 0.75rem', fontSize: '0.85rem' }}
      >
        {open ? 'Hide availability' : 'Check availability'}
      </button>
      {open && (
        <div style={{ marginTop: '0.5rem' }}>
          {err && <p className="error">{err}</p>}
          {slots === null && !err && <p className="muted">Loading…</p>}
          {slots !== null && slots.length === 0 && <p className="muted">No bookings — all slots are open.</p>}
          {slots !== null && slots.length > 0 && (
            <ul style={{ listStyle: 'none', padding: 0, margin: 0 }}>
              {slots.map((s) => (
                <li key={s.id} className="muted" style={{ fontSize: '0.85rem' }}>
                  {new Date(s.starts_at).toLocaleString()} → {new Date(s.ends_at).toLocaleString()} ({s.status})
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// PhotoGallery — renders stored photos and (for authed users) an upload form.
// The file field accepts up to 6 images (png/jpeg/webp, 5 MB each).
// ---------------------------------------------------------------------------
function PhotoGallery({ listing, canUpload, onUploaded }: {
  listing: Listing;
  canUpload: boolean;
  onUploaded: (updated: Listing) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const photos = listing.photos ?? [];

  async function upload(e: React.ChangeEvent<HTMLInputElement>) {
    const input = e.target;
    const files = Array.from(input.files ?? []);
    if (!files.length) return;
    setBusy(true); setErr(null);
    try {
      const updated = await uploadListingPhotos(listing.id, files);
      onUploaded(updated);
    } catch (ex: unknown) {
      setErr(ex instanceof Error ? ex.message : String(ex));
    } finally {
      setBusy(false);
      // Reset the input so selecting the SAME file again still fires onChange.
      input.value = '';
    }
  }

  return (
    <div style={{ marginBottom: '0.75rem' }}>
      {photos.length > 0 && (
        <div style={{ display: 'flex', gap: '0.5rem', flexWrap: 'wrap', marginBottom: '0.5rem' }}>
          {photos.map((name) => (
            <img
              key={name}
              src={photoUrl(listing.id, name)}
              alt={listing.title}
              style={{ width: 96, height: 72, objectFit: 'cover', borderRadius: 3, border: '1px solid var(--hairline)' }}
            />
          ))}
        </div>
      )}
      {canUpload && (
        <label style={{ fontSize: '0.85rem', color: 'var(--muted)', cursor: 'pointer' }}>
          {busy ? 'Uploading…' : '+ Add photos (png/jpeg/webp, ≤5 MB each, up to 6)'}
          <input
            type="file"
            accept="image/png,image/jpeg,image/webp"
            multiple
            disabled={busy}
            onChange={upload}
            style={{ display: 'none' }}
          />
        </label>
      )}
      {err && <p className="error">{err}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------
// BookForm — date-range picker + submit.
// ---------------------------------------------------------------------------
function BookForm({ listing }: { listing: Listing }) {
  const [start, setStart] = useState('');
  const [end, setEnd] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [booked, setBooked] = useState<number | null>(null);

  async function book() {
    setBusy(true); setError(null);
    try {
      // datetime-local gives "YYYY-MM-DDTHH:MM" in the user's LOCAL time;
      // appending ":00Z" treats it as UTC — fine for a demo, wrong across
      // timezones. Use a timezone-aware conversion in a real app.
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

// ---------------------------------------------------------------------------
// ListingsBrowser — main component for the home page.
// ---------------------------------------------------------------------------
export default function ListingsBrowser() {
  const [authed, setAuthed] = useState(() => token() !== null);
  const [listings, setListings] = useState<Listing[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    listListings()
      .then(setListings)
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
  }, []);

  function updateListing(updated: Listing) {
    setListings((prev) => prev?.map((l) => (l.id === updated.id ? updated : l)) ?? null);
  }

  if (error) return <p className="error">Failed to load listings: {error}</p>;
  if (!listings) return <p className="muted">Loading…</p>;
  return (
    <>
      {!authed && <Auth onAuthed={() => setAuthed(true)} />}
      {listings.length === 0 && (
        <p className="muted">
          No published listings yet — create a simulator + listing via the{' '}
          <a href="/_/" data-astro-reload>admin UI</a> or the API (see the README).
        </p>
      )}
      {listings.map((l) => (
        <article className="card" key={l.id}>
          <h2>{l.title}</h2>
          <p className="muted">
            {l.expand?.simulator?.label ?? 'simulator'} ·{' '}
            <span className="price">${l.price_per_hour}</span>/hour
          </p>
          {/* Photos — always shown; upload only for authed users */}
          <PhotoGallery listing={l} canUpload={authed} onUploaded={updateListing} />
          {/* Availability calendar (lazy-loaded) — shown to authed users */}
          {authed && <AvailabilityPanel listing={l} />}
          {authed ? <BookForm listing={l} /> : <p className="muted">Sign in above to book.</p>}
        </article>
      ))}
    </>
  );
}
