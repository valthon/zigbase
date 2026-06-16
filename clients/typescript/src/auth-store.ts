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
  save(token: string, record: AuthRecord): void;
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

  save(token: string, record: AuthRecord): void {
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
