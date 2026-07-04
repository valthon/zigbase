// --- cookie + API client (cookie/CSRF auth; no token in JS) ---
export function cookie(name) {
  const m = document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]*)'));
  return m ? decodeURIComponent(m[1]) : '';
}
export async function api(method, path, body, isForm) {
  const headers = {};
  if (!['GET', 'HEAD'].includes(method)) headers['X-CSRF-Token'] = cookie('zb_csrf');
  let payload = body;
  if (body != null && !isForm) { headers['Content-Type'] = 'application/json'; payload = JSON.stringify(body); }
  const res = await fetch('/api' + path, { method, headers, body: payload, credentials: 'same-origin' });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (res.status === 401 || res.status === 403) { location.hash = '#/login'; throw { status: res.status, data }; }
  if (!res.ok) throw { status: res.status, data };
  return data;
}
export const API = {
  // Read-only backend badge (no secrets): { status, backend: 'sqlite' | 'postgres' }.
  health: () => api('GET', '/health'),
  login: (identity, password) => api('POST', '/collections/_superusers/auth-with-password', { identity, password }),
  logout: () => api('POST', '/collections/_superusers/auth-logout'),
  collections: () => api('GET', '/collections').then(r => r.items),
  records: (col, q) => api('GET', `/collections/${encodeURIComponent(col)}/records?${q}`),
  createCollection: (payload) => api('POST', '/collections', payload),
  updateCollection: (name, payload) => api('PATCH', `/collections/${encodeURIComponent(name)}`, payload),
  deleteCollection: (name) => api('DELETE', `/collections/${encodeURIComponent(name)}`),
  refresh: () => api('POST', '/collections/_superusers/auth-refresh'),
  settingsList: () => api('GET', '/settings').then(r => r.items),
  settingsPut: (key, value) => api('PUT', `/settings/${encodeURIComponent(key)}`, { value }),
  settingsDelete: (key) => api('DELETE', `/settings/${encodeURIComponent(key)}`),
  featuresList: () => api('GET', '/features'),
  // Flag/experiment override helpers — build the path with a literal ':' so the
  // router sees 'flag:<name>' or 'exp:<name>:weights' as the key (encodeURIComponent
  // would encode the ':' to '%3A', creating a different key in _kv).
  flagOverridePut: (name, value) => api('PUT', `/settings/flag:${encodeURIComponent(name)}`, { value }),
  flagOverrideDel: (name) => api('DELETE', `/settings/flag:${encodeURIComponent(name)}`),
  expWeightsPut: (name, json) => api('PUT', `/settings/exp:${encodeURIComponent(name)}:weights`, { value: json }),
  expWeightsDel: (name) => api('DELETE', `/settings/exp:${encodeURIComponent(name)}:weights`),
};
