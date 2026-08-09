export interface FieldError {
  code: string;
  message: string;
}

export interface ZigbaseErrorInit {
  status: number;
  /** Frozen machine code from the response envelope. See `ZigbaseError.code`. */
  code?: string;
  message: string;
  data?: Record<string, FieldError>;
  url: string;
  response?: Response;
}

export class ZigbaseError extends Error {
  readonly status: number;
  /**
   * The envelope's frozen machine code (`"not_found"`, `"validation_failed"`,
   * `"email_not_verified"`, …) — branch on THIS, never on `message`, whose wording is
   * explicitly not part of the API contract and may change in any release.
   *
   * `""` when the server sent no code: a non-JSON body, or a response from something
   * that isn't ZigBase (a proxy's own 502 page). Check for a non-empty value before
   * matching if you need to tell those apart.
   */
  readonly code: string;
  readonly data: Record<string, FieldError>;
  readonly url: string;
  readonly response?: Response;

  constructor(init: ZigbaseErrorInit) {
    super(init.message);
    this.name = "ZigbaseError";
    this.status = init.status;
    this.code = init.code ?? "";
    this.data = init.data ?? {};
    this.url = init.url;
    this.response = init.response;
  }
}

export function isZigbaseError(e: unknown): e is ZigbaseError {
  return e instanceof ZigbaseError;
}

export async function parseErrorResponse(res: Response, url: string): Promise<ZigbaseError> {
  let message = res.statusText || `Request failed with status ${res.status}`;
  let code = "";
  let data: Record<string, FieldError> = {};
  try {
    const body = (await res.clone().json()) as {
      code?: unknown;
      message?: string;
      data?: Record<string, FieldError>;
    };
    if (body && typeof body.message === "string") message = body.message;
    // Only a STRING code is the machine code. Pre-unification servers put the integer
    // HTTP status here, so a number must never be surfaced as if it were a code.
    if (body && typeof body.code === "string") code = body.code;
    if (body && body.data && typeof body.data === "object") data = body.data;
  } catch {
    // non-JSON body; keep status-text fallback
  }
  return new ZigbaseError({ status: res.status, code, message, data, url, response: res });
}
