import { isTokenExpired } from "./jwt.js";

export interface AuthRecord {
  id: string;
  [key: string]: unknown;
}

export type AuthChangeListener = (
  token: string | null,
  record: AuthRecord | null,
) => void;

export interface AuthStore {
  readonly token: string | null;
  readonly record: AuthRecord | null;
  readonly isValid: boolean;
  save(token: string, record: AuthRecord | null): void;
  clear(): void;
  onChange(cb: AuthChangeListener): () => void;
}

export class BaseAuthStore implements AuthStore {
  protected _token: string | null = null;
  protected _record: AuthRecord | null = null;
  private listeners = new Set<AuthChangeListener>();

  get token(): string | null {
    return this._token;
  }
  get record(): AuthRecord | null {
    return this._record;
  }
  get isValid(): boolean {
    return this._token !== null && !isTokenExpired(this._token);
  }

  save(token: string, record: AuthRecord | null): void {
    this._token = token;
    this._record = record;
    this.emit();
  }

  clear(): void {
    this._token = null;
    this._record = null;
    this.emit();
  }

  onChange(cb: AuthChangeListener): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  protected emit(): void {
    for (const cb of this.listeners) cb(this._token, this._record);
  }
}

export class MemoryAuthStore extends BaseAuthStore {}

interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

export class LocalAuthStore extends BaseAuthStore {
  constructor(
    private readonly key = "zb_auth",
    private readonly storage: StorageLike | undefined = globalThis.localStorage,
  ) {
    super();
    this.rehydrate();
  }

  private rehydrate(): void {
    const raw = this.storage?.getItem(this.key);
    if (!raw) return;
    try {
      const parsed = JSON.parse(raw) as { token: string; record: AuthRecord };
      this._token = parsed.token ?? null;
      this._record = parsed.record ?? null;
    } catch {
      // ignore corrupt storage
    }
  }

  override save(token: string, record: AuthRecord | null): void {
    this.storage?.setItem(this.key, JSON.stringify({ token, record }));
    super.save(token, record);
  }

  override clear(): void {
    this.storage?.removeItem(this.key);
    super.clear();
  }
}

export interface CookieSerializeOptions {
  path?: string;
  maxAge?: number;
  sameSite?: "strict" | "lax" | "none";
  secure?: boolean;
}

export class CookieAuthStore extends BaseAuthStore {
  constructor(private readonly key = "zb_auth") {
    super();
  }

  exportToCookie(opts: CookieSerializeOptions = {}): string {
    const value = encodeURIComponent(
      JSON.stringify({ token: this._token, record: this._record }),
    );
    const parts = [`${this.key}=${value}`, `Path=${opts.path ?? "/"}`];
    if (opts.maxAge !== undefined) parts.push(`Max-Age=${opts.maxAge}`);
    parts.push(`SameSite=${opts.sameSite ?? "Strict"}`);
    if (opts.secure) parts.push("Secure");
    return parts.join("; ");
  }

  loadFromCookie(cookieHeader: string): void {
    // `req.headers.cookie` may be undefined; guard before splitting.
    if (typeof cookieHeader !== "string" || cookieHeader.length === 0) return;
    const match = cookieHeader
      .split(";")
      .map((c) => c.trim())
      .find((c) => c.startsWith(`${this.key}=`));
    if (!match) return;
    try {
      const raw = decodeURIComponent(match.slice(this.key.length + 1));
      const parsed = JSON.parse(raw) as { token: string | null; record: AuthRecord | null };
      this._token = parsed.token ?? null;
      this._record = parsed.record ?? null;
      this.emit();
    } catch {
      // ignore malformed cookie
    }
  }
}
