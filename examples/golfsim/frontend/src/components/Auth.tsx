import { useState } from 'react';
import { login, signup } from '../lib/api';

export default function Auth({ onAuthed }: { onAuthed: () => void }) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<void>) {
    setBusy(true); setError(null);
    try { await fn(); onAuthed(); } catch (e: unknown) { setError(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  }

  return (
    <div className="card">
      <h2>Sign in to book</h2>
      <input placeholder="email" value={email} onChange={(e) => setEmail(e.target.value)} />
      <input placeholder="password (8+ chars)" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
      <button disabled={busy} onClick={() => run(() => login(email, password))}>Log in</button>{' '}
      <button disabled={busy} onClick={() => run(() => signup(email, password))}>Sign up</button>
      {error && <p className="error">{error}</p>}
    </div>
  );
}
