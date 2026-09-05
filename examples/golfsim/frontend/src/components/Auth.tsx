import { useState } from '@z/runtime';
import {
  login,
  signup,
  requestVerification,
  confirmVerification,
  otpInitiate,
  otpComplete,
  EmailNotVerifiedError,
  SecondFactorRequiredError,
  type PendingAuthentication,
} from '../lib/api';
import { SecondFactor } from './SecondFactor';

type Step = 'signin' | 'signup' | 'verify' | 'otp_sent';

/**
 * Multi-step auth card covering:
 *   signin    — email + password login, or "Send one-time code" (OTP)
 *   signup    — create account → triggers verification email → step verify
 *   verify    — paste verification token from email → step signin (with success banner)
 *   otp_sent  — enter 6-digit OTP code → calls onAuthed()
 *
 * The onAuthed prop is unchanged — both ListingsBrowser and MyBookings pass
 * onAuthed={() => setAuthed(true)}.
 *
 * Unverified-email detection: when login() throws EmailNotVerifiedError the
 * component switches to the verify step with the email pre-filled.
 *
 * OAuth2 (Google): a direct link to /api/collections/users/auth/oauth2/google/authorize
 * redirects the browser to Google; the server handles the PKCE/callback dance and
 * sets a session cookie on return. Requires ZIGBASE_OAUTH_GOOGLE_CLIENT_ID/SECRET env vars.
 */
export default function Auth({ onAuthed }: { onAuthed: () => void }) {
  const [step, setStep] = useState<Step>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [verifyToken, setVerifyToken] = useState('');
  const [otpCode, setOtpCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [pending, setPending] = useState<PendingAuthentication | null>(null);

  function reset(nextStep: Step, infoMsg?: string) {
    setError(null);
    setInfo(infoMsg ?? null);
    setStep(nextStep);
  }

  async function run(fn: () => Promise<void>) {
    setBusy(true);
    setError(null);
    setInfo(null);
    try {
      await fn();
    } catch (e: unknown) {
      if (e instanceof SecondFactorRequiredError) {
        setPending(e.pending);
        return;
      }
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  // ── Sign in with password ─────────────────────────────────────────────────
  async function handleLoginPassword() {
    await run(async () => {
      try {
        await login(email, password);
        onAuthed();
      } catch (e) {
        if (e instanceof EmailNotVerifiedError) {
          // Account exists but email is not yet verified — jump to verify step.
          setInfo('Your email is not yet verified. Paste the token from your inbox below.');
          setError(null);
          setStep('verify');
          return;
        }
        throw e;
      }
    });
  }

  // ── Sign up ───────────────────────────────────────────────────────────────
  async function handleSignup() {
    await run(async () => {
      await signup(email, password);
      // signup() calls requestVerification() internally; verification email is in flight.
      reset('verify');
    });
  }

  // ── Verify email ──────────────────────────────────────────────────────────
  async function handleVerify() {
    await run(async () => {
      await confirmVerification(verifyToken);
      setVerifyToken('');
      reset('signin', 'Account verified. Sign in to continue.');
    });
  }

  async function handleResendVerification() {
    await run(async () => {
      await requestVerification(email);
      setInfo('Verification email resent. Check your inbox (or server log in dev).');
    });
  }

  // ── OTP ───────────────────────────────────────────────────────────────────
  async function handleSendOtp() {
    await run(async () => {
      await otpInitiate(email);
      setOtpCode('');
      reset('otp_sent');
    });
  }

  async function handleOtpComplete() {
    await run(async () => {
      await otpComplete(email, otpCode);
      onAuthed();
    });
  }

  // ── Render ────────────────────────────────────────────────────────────────
  if (pending) return <SecondFactor pending={pending} onDone={onAuthed} />;
  return (
    <div className="card">
      {info && <p className="info">{info}</p>}

      {/* ── Sign in ── */}
      {step === 'signin' && (
        <>
          <h2>Sign in to book</h2>
          <input
            placeholder="Email"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.currentTarget.value)}
          />
          <input
            placeholder="Password"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.currentTarget.value)}
          />
          <div style={{ display: 'flex', gap: '0.5rem', flexWrap: 'wrap' }}>
            <button disabled={busy} onClick={handleLoginPassword}>
              Log in with password
            </button>
            <button disabled={busy} onClick={handleSendOtp} style={{ background: '#555' }}>
              Send one-time code
            </button>
          </div>
          {/* OAuth2: browser redirect to Google. Real creds required — see README. */}
          <div style={{ marginTop: '0.5rem' }}>
            <a
              href="/api/collections/users/auth/oauth2/google/authorize"
              style={{
                display: 'inline-block',
                padding: '0.5rem 1rem',
                background: '#4285F4',
                color: '#fff',
                borderRadius: '4px',
                textDecoration: 'none',
                fontSize: '0.95rem',
              }}
            >
              Sign in with Google
            </a>
          </div>
          <p style={{ marginTop: '0.75rem', fontSize: '0.9rem' }}>
            New here?{' '}
            <button
              style={{ background: 'none', border: 'none', color: '#4af', cursor: 'pointer', textDecoration: 'underline' }}
              onClick={() => reset('signup')}
            >
              Sign up
            </button>
          </p>
        </>
      )}

      {/* ── Sign up ── */}
      {step === 'signup' && (
        <>
          <h2>Create an account</h2>
          <input
            placeholder="Email"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.currentTarget.value)}
          />
          <input
            placeholder="Password (8+ chars)"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.currentTarget.value)}
          />
          <button disabled={busy} onClick={handleSignup}>
            Create account
          </button>
          <p style={{ marginTop: '0.75rem', fontSize: '0.9rem' }}>
            Already have an account?{' '}
            <button
              style={{ background: 'none', border: 'none', color: '#4af', cursor: 'pointer', textDecoration: 'underline' }}
              onClick={() => reset('signin')}
            >
              Sign in
            </button>
          </p>
        </>
      )}

      {/* ── Verify email ── */}
      {step === 'verify' && (
        <>
          <h2>Verify your email</h2>
          <p>
            Check your inbox (or the server log in dev) for a verification token,
            then paste it below.
          </p>
          <input
            placeholder="Verification token"
            value={verifyToken}
            onChange={(e) => setVerifyToken(e.currentTarget.value)}
          />
          <button disabled={busy} onClick={handleVerify}>
            Verify
          </button>
          {email && (
            <p style={{ marginTop: '0.5rem', fontSize: '0.9rem' }}>
              Didn't get it?{' '}
              <button
                style={{ background: 'none', border: 'none', color: '#4af', cursor: 'pointer', textDecoration: 'underline' }}
                disabled={busy}
                onClick={handleResendVerification}
              >
                Resend
              </button>
            </p>
          )}
          <p style={{ marginTop: '0.5rem', fontSize: '0.9rem' }}>
            <button
              style={{ background: 'none', border: 'none', color: '#4af', cursor: 'pointer', textDecoration: 'underline' }}
              onClick={() => reset('signin')}
            >
              Back to sign in
            </button>
          </p>
        </>
      )}

      {/* ── OTP code entry ── */}
      {step === 'otp_sent' && (
        <>
          <h2>Check your email</h2>
          <p>
            We sent a 6-digit code to <strong>{email}</strong>. It's valid for 5 minutes.
            <br />
            In dev, the code is printed to the server log by the LogMailer.
          </p>
          <input
            placeholder="6-digit code"
            type="text"
            inputMode="numeric"
            maxLength={6}
            value={otpCode}
            onChange={(e) => setOtpCode(e.currentTarget.value)}
          />
          <button disabled={busy} onClick={handleOtpComplete}>
            Confirm code
          </button>
          <p style={{ marginTop: '0.5rem', fontSize: '0.9rem' }}>
            <button
              style={{ background: 'none', border: 'none', color: '#4af', cursor: 'pointer', textDecoration: 'underline' }}
              onClick={() => reset('signin')}
            >
              Back to sign in
            </button>
          </p>
        </>
      )}

      {error && <p className="error">{error}</p>}
    </div>
  );
}
