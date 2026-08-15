import { useState, useEffect } from '@z/runtime';
import { getMe, logout, logoutCookie, type Me } from '../lib/api';

export interface Props {}

export default function AuthStatus(_props: Props) {
  const [me, setMe] = useState<Me | null>(null);
  const [checked, setChecked] = useState(false);

  useEffect(() => {
    getMe().then((m) => { setMe(m); setChecked(true); });
  }, []);

  if (!checked) return null; // avoid layout flash while fetching

  if (!me) return null; // not logged in — show nothing in the nav

  return (
    <span className="auth-status">
      {me.email}{' '}
      <button
        className="muted"
        onClick={() => { logout(); logoutCookie(); setMe(null); }}
      >
        log out
      </button>
    </span>
  );
}
