import { useEffect, useState } from '@z/runtime';
import { beginTotp, enrollSecondFactor, finishSecondFactor, type PendingAuthentication } from '../lib/api';

export function SecondFactor({ pending, onDone }: { pending: PendingAuthentication; onDone: () => void }) {
  const [ceremony, setCeremony] = useState<{ ceremonyId: string; secret: string } | null>(null);
  const [code, setCode] = useState('');
  const [recovery, setRecovery] = useState(false);
  const [codes, setCodes] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const enrolling = pending.status === 'enrollment_required';

  useEffect(() => {
    if (!enrolling) return;
    beginTotp(pending.pendingToken).then(setCeremony).catch((e: Error) => setError(e.message));
  }, [pending.pendingToken]);

  async function submit() {
    setBusy(true);
    setError('');
    try {
      const recoveryCodes = await finishSecondFactor(pending.pendingToken, code.trim(), ceremony?.ceremonyId, recovery);
      setCode('');
      if (recoveryCodes.length) setCodes(recoveryCodes);
      else onDone();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      // Enrollment challenges are single-use, including on an incorrect code.
      if (enrolling) {
        try { setCeremony(await beginTotp(pending.pendingToken)); }
        catch { setCeremony(null); }
      }
    } finally { setBusy(false); }
  }

  if (codes.length) return <section className="card" data-test="recovery-codes">
    <h2>Save your recovery codes</h2>
    <p>Keep these somewhere private. Each code works once if you lose access to your authenticator.</p>
    <pre>{codes.join('\n')}</pre>
    <button onClick={() => { setCodes([]); onDone(); }}>I saved my recovery codes</button>
  </section>;

  return <section className="card" data-test="second-factor">
    <h2>{enrolling ? 'Set up two-factor authentication' : 'Verify your sign-in'}</h2>
    {enrolling && <>
      <p>Add a time-based account in your authenticator app using this setup key, then enter its six-digit code.</p>
      {ceremony && <code data-test="totp-secret">{ceremony.secret}</code>}
    </>}
    <label>
      {recovery ? 'Recovery code' : 'Authenticator code'}
      <input data-test="second-factor-code" autoComplete="one-time-code" inputMode={recovery ? 'text' : 'numeric'} value={code} onChange={(e) => setCode(e.currentTarget.value)} />
    </label>
    <button data-test="second-factor-submit" disabled={busy || (enrolling && !ceremony)} onClick={submit}>Verify</button>
    {!enrolling && <button onClick={() => { setRecovery(!recovery); setCode(''); }}>
      {recovery ? 'Use my authenticator' : 'Use a recovery code'}
    </button>}
    {error && <p className="error">{error}</p>}
  </section>;
}

export function SecuritySettings() {
  const [pending, setPending] = useState<PendingAuthentication | null>(null);
  const [message, setMessage] = useState('');
  if (pending) return <SecondFactor pending={pending} onDone={() => { setPending(null); setMessage('Two-factor authentication is enabled.'); }} />;
  return <section className="card">
    <h2>Account security</h2>
    <p>Protect your sign-ins with an authenticator app.</p>
    <button data-test="enable-two-factor" onClick={async () => {
      try { setPending(await enrollSecondFactor()); }
      catch (e) { setMessage(e instanceof Error ? e.message : String(e)); }
    }}>Enable two-factor authentication</button>
    {message && <p>{message}</p>}
  </section>;
}
