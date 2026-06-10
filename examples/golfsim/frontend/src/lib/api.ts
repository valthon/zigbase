const TOKEN_KEY = 'golfsim_token';

export type Listing = {
  id: string;
  title: string;
  price_per_hour: number;
  status: string;
  simulator: string;
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
  if (init.body) headers['Content-Type'] = 'application/json';
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
  // The example's beforeCreate hook validates the listing, computes price_total,
  // stamps the guest from the auth token, and forces status=pending.
  return req('/api/collections/bookings/records', {
    method: 'POST',
    body: JSON.stringify({ listing: listingId, starts_at: startsAt, ends_at: endsAt }),
  });
}

export async function myBookings(): Promise<Booking[]> {
  // The list rule restricts results to the caller's own bookings.
  const out = await req('/api/collections/bookings/records?expand=listing&sort=-created');
  return out.items;
}

export async function confirmBooking(id: string): Promise<Booking> {
  // The example's custom business route.
  return req(`/api/bookings/${id}/confirm`, { method: 'POST' });
}
