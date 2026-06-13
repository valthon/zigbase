const TOKEN_KEY = 'golfsim_token';

export type Listing = {
  id: string;
  title: string;
  price_per_hour: number;
  status: string;
  simulator: string;
  /** Stored filenames — build full URL with photoUrl(). */
  photos?: string[];
  expand?: { simulator?: { label: string } };
};

export type Booking = {
  id: string;
  listing: string;
  starts_at: string;
  ends_at: string;
  price_total: number;
  status: string;
  expand?: { listing?: Listing };
};

export type AvailabilitySlot = {
  id: string;
  starts_at: string;
  ends_at: string;
  status: string;
};

export type Review = {
  id: string;
  booking: string;
  author: string;
  rating: number;
  body: string;
  created: string;
};

export function token(): string | null {
  if (typeof localStorage === 'undefined') return null;
  return localStorage.getItem(TOKEN_KEY);
}

export function logout(): void {
  if (typeof localStorage !== 'undefined') localStorage.removeItem(TOKEN_KEY);
}

async function req(path: string, init: RequestInit = {}): Promise<any> {
  const headers: Record<string, string> = {};
  const t = token();
  if (t) headers['Authorization'] = `Bearer ${t}`;
  // Only set Content-Type for JSON strings — omit it for FormData so the
  // browser can set the correct multipart boundary automatically.
  if (init.body && typeof init.body === 'string') headers['Content-Type'] = 'application/json';
  const r = await fetch(path, { ...init, headers });
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    throw new Error(err?.message ?? `HTTP ${r.status}`);
  }
  return r.json();
}

export async function login(email: string, password: string): Promise<void> {
  const out = await req('/api/collections/users/auth-with-password', {
    method: 'POST',
    body: JSON.stringify({ identity: email, password }),
  });
  if (typeof localStorage !== 'undefined') localStorage.setItem(TOKEN_KEY, out.token);
}

export async function signup(email: string, password: string): Promise<void> {
  await req('/api/collections/users/records', {
    method: 'POST',
    body: JSON.stringify({ email, password, passwordConfirm: password }),
  });
  await login(email, password);
}

export async function listListings(): Promise<Listing[]> {
  const out = await req('/api/collections/listings/records?expand=simulator&sort=-created');
  return out.items;
}

export async function createBooking(listingId: string, startsAt: string, endsAt: string): Promise<Booking> {
  // The beforeCreate hook validates the listing, checks for overlapping bookings
  // (double-booking prevention), computes price_total, stamps the guest from the
  // auth token, and forces status=pending.
  return req('/api/collections/bookings/records', {
    method: 'POST',
    body: JSON.stringify({ listing: listingId, starts_at: startsAt, ends_at: endsAt }),
  });
}

export async function myBookings(): Promise<Booking[]> {
  // The list rule restricts results to the caller's own bookings (or listings
  // owned by the caller's simulator).
  const out = await req('/api/collections/bookings/records?expand=listing&sort=-created');
  return out.items;
}

export async function confirmBooking(id: string): Promise<Booking> {
  // Custom route — verifies the caller is the simulator owner before confirming.
  return req(`/api/bookings/${id}/confirm`, { method: 'POST' });
}

export async function cancelBooking(id: string): Promise<Booking> {
  // Custom route — verifies the caller is the booking's guest.
  return req(`/api/bookings/${id}/cancel`, { method: 'POST' });
}

export async function getAvailability(listingId: string): Promise<AvailabilitySlot[]> {
  // Custom route — returns non-cancelled bookings for the listing so the UI
  // can show a calendar and warn on overlap before the user submits.
  const out = await req(`/api/listings/${listingId}/availability`);
  return out.items ?? [];
}

export async function uploadListingPhotos(listingId: string, files: File[]): Promise<Listing> {
  // Photo upload uses multipart/form-data. Do NOT set Content-Type — the
  // browser sets it automatically with the correct multipart boundary.
  // Serve stored photos via photoUrl().
  const form = new FormData();
  for (const f of files) form.append('photos', f);
  return req(`/api/collections/listings/records/${listingId}`, {
    method: 'PATCH',
    body: form,
  });
}

/** Build a URL for a stored listing photo. Published listings serve directly. */
export function photoUrl(listingId: string, filename: string): string {
  return `/api/files/listings/${listingId}/${filename}`;
}

export async function createReview(bookingId: string, rating: number, body: string): Promise<Review> {
  // The prepareReview beforeCreate hook stamps the author from the auth token and
  // enforces that the booking is the caller's own AND confirmed (else HTTP 400).
  return req('/api/collections/reviews/records', {
    method: 'POST',
    body: JSON.stringify({ booking: bookingId, rating, body }),
  });
}

// ---------------------------------------------------------------------------
// Realtime helpers — subscribe to bookings changes via the WebSocket endpoint.
//
// Protocol:
//   1. Open WS to /api/realtime
//   2. On open: send { action:"auth", token:<jwt> }
//   3. Wait for { type:"auth", status:"ok" }
//   4. Send { action:"subscribe", topic:"bookings" }
//   5. Receive { type:"event", topic:"bookings", action:"create"|"update"|"delete", record }
//
// Returns a cleanup function that closes the socket.
// ---------------------------------------------------------------------------
export type RealtimeEvent = {
  type: string;
  topic: string;
  action: 'create' | 'update' | 'delete';
  record: Booking;
};

export function subscribeBookings(onEvent: (ev: RealtimeEvent) => void): () => void {
  const t = token();
  if (!t) return () => {};

  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/api/realtime`);
  let authed = false;

  ws.onopen = () => {
    ws.send(JSON.stringify({ action: 'auth', token: t }));
  };

  ws.onmessage = (msgEv) => {
    let msg: any;
    try { msg = JSON.parse(msgEv.data as string); } catch { return; }

    if (!authed && msg.type === 'auth' && msg.status === 'ok') {
      authed = true;
      ws.send(JSON.stringify({ action: 'subscribe', topic: 'bookings' }));
      return;
    }

    if (msg.type === 'event' && msg.topic === 'bookings') {
      onEvent(msg as RealtimeEvent);
    }
  };

  ws.onerror = () => {};   // suppress unhandled-rejection noise in SSR

  return () => ws.close();
}
