import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  listListings, myBookings, createBooking, createReview, confirmBooking,
  cancelBooking, getAvailability, uploadListingPhotos, photoUrl, signup,
  login, otpComplete, finishSecondFactor, SecondFactorRequiredError,
} from '../frontend/src/lib/api';

const storage = new Map<string, string>();
const request = vi.fn<Parameters<typeof fetch>, ReturnType<typeof fetch>>();
beforeEach(() => {
  storage.clear();
  request.mockReset();
  vi.stubGlobal('localStorage', {
    getItem: (k: string) => storage.get(k) ?? null,
    setItem: (k: string, v: string) => storage.set(k, v),
    removeItem: (k: string) => storage.delete(k),
  });
  vi.stubGlobal('document', { cookie: 'zb_csrf=csrf%2Ftoken' });
  vi.stubGlobal('fetch', request);
});
afterEach(() => { vi.unstubAllGlobals(); });

function json(value: unknown) {
  return new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
}

describe('Golfsim browser API using the generated client', () => {
  it('uses typed collection services with relation expansion and sort', async () => {
    request.mockResolvedValueOnce(json({ items: [{ id: 'listing', expand: { simulator: { label: 'Bay' } } }] }));
    expect((await listListings())[0]?.expand?.simulator?.label).toBe('Bay');
    const url = new URL(String(request.mock.calls[0]![0]), 'http://example.test');
    expect(url.pathname).toBe('/api/collections/listings/records');
    expect(url.searchParams.get('expand')).toBe('simulator');
    expect(url.searchParams.get('sort')).toBe('-created');
    request.mockResolvedValueOnce(json({ items: [] }));
    await myBookings();
    const bookings = new URL(String(request.mock.calls[1]![0]), 'http://example.test');
    expect(bookings.searchParams.get('expand')).toBe('listing');
  });

  it('preserves cookie/CSRF policy and reads the current token for every call', async () => {
    storage.set('golfsim_token', 'first-token');
    request.mockResolvedValueOnce(json({ id: 'booking' }));
    await createBooking('listing', 'start', 'end');
    const first = request.mock.calls[0]![1]!;
    expect(new Headers(first.headers).get('authorization')).toBe('Bearer first-token');
    expect(new Headers(first.headers).get('x-csrf-token')).toBe('csrf/token');
    expect(first.credentials).toBe('include');
    expect(JSON.parse(String(first.body))).toEqual({ listing: 'listing', starts_at: 'start', ends_at: 'end' });
    storage.set('golfsim_token', 'second-token');
    request.mockResolvedValueOnce(json({ id: 'review' }));
    await createReview('booking', 5, 'Great');
    const second = request.mock.calls[1]![1]!;
    expect(new Headers(second.headers).get('authorization')).toBe('Bearer second-token');
    expect(JSON.parse(String(second.body))).toEqual({ booking: 'booking', rating: 5, body: 'Great' });
    storage.clear();
    request.mockResolvedValueOnce(json({ items: [] }));
    await listListings();
    expect(new Headers(request.mock.calls[2]![1]!.headers).has('authorization')).toBe(false);
  });

  it('uses generated RPC path encoding and escaped file URLs', async () => {
    request.mockResolvedValueOnce(json({ id: 'booking' }));
    await confirmBooking('id/with ?');
    expect(request.mock.calls[0]![0]).toBe('/api/bookings/id%2Fwith%20%3F/confirm');
    request.mockResolvedValueOnce(json({ id: 'booking' }));
    await cancelBooking('id/with ?');
    expect(request.mock.calls[1]![0]).toBe('/api/bookings/id%2Fwith%20%3F/cancel');
    request.mockResolvedValueOnce(json({ items: [] }));
    expect(await getAvailability('id/with ?')).toEqual([]);
    expect(request.mock.calls[2]![0]).toBe('/api/listings/id%2Fwith%20%3F/availability');
    expect(photoUrl('id/with ?', 'photo #1.png')).toBe('/api/files/listings/id%2Fwith%20%3F/photo%20%231.png');
  });

  it('builds photo URLs without reading browser credentials or making requests', () => {
    const getItem = vi.fn(() => { throw new Error('storage unavailable'); });
    vi.stubGlobal('localStorage', { getItem });
    expect(photoUrl('listing', 'photo.png')).toBe('/api/files/listings/listing/photo.png');
    expect(photoUrl('listing', 'another.png')).toBe('/api/files/listings/listing/another.png');
    expect(getItem).not.toHaveBeenCalled();
    expect(request).not.toHaveBeenCalled();
  });

  it('lets the SDK encode file arrays as multipart without a JSON content type', async () => {
    request.mockResolvedValueOnce(json({ id: 'listing' }));
    request.mockResolvedValueOnce(json({ id: 'listing', expand: { simulator: { label: 'Bay' } } }));
    const photo = new File(['image'], 'photo.png', { type: 'image/png' });
    const listing = await uploadListingPhotos('listing', [photo]);
    expect(listing.expand?.simulator?.label).toBe('Bay');
    expect(request.mock.calls[1]![0]).toBe('/api/collections/listings/records/listing?expand=simulator');
    const init = request.mock.calls[0]![1]!;
    expect(init.method).toBe('PATCH');
    expect(init.body).toBeInstanceOf(FormData);
    expect((init.body as FormData).getAll('photos')).toEqual([photo]);
    expect(new Headers(init.headers).has('content-type')).toBe(false);
    expect(new Headers(init.headers).get('x-csrf-token')).toBe('csrf/token');
  });

  it('keeps signup verification and pending second-factor responses out of session storage', async () => {
    request.mockResolvedValueOnce(json({ id: 'user' })).mockResolvedValueOnce(new Response(null, { status: 204 }));
    await signup('user@example.test', 'password');
    expect(request.mock.calls[1]![0]).toBe('/api/collections/users/request-verification');
    const pending = { status: 'factor_required', pendingToken: 'pending' };
    for (const primary of [() => login('user@example.test', 'password'), () => otpComplete('user@example.test', '123456')]) {
      storage.set('golfsim_token', 'old');
      request.mockResolvedValueOnce(json(pending));
      await expect(primary()).rejects.toBeInstanceOf(SecondFactorRequiredError);
      expect(storage.has('golfsim_token')).toBe(false);
    }
    request.mockResolvedValueOnce(json({ token: 'session', recoveryCodes: ['recovery'] }));
    expect(await finishSecondFactor('pending', '123456')).toEqual(['recovery']);
    expect(storage.get('golfsim_token')).toBe('session');
  });
});
