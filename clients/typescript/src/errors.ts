export interface FieldError {
  code: string;
  message: string;
}

export interface ZigbaseErrorInit {
  status: number;
  message: string;
  data?: Record<string, FieldError>;
  url: string;
  response?: Response;
}

export class ZigbaseError extends Error {
  readonly status: number;
  readonly data: Record<string, FieldError>;
  readonly url: string;
  readonly response?: Response;

  constructor(init: ZigbaseErrorInit) {
    super(init.message);
    this.name = "ZigbaseError";
    this.status = init.status;
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
  let data: Record<string, FieldError> = {};
  try {
    const body = (await res.clone().json()) as {
      message?: string;
      data?: Record<string, FieldError>;
    };
    if (body && typeof body.message === "string") message = body.message;
    if (body && body.data && typeof body.data === "object") data = body.data;
  } catch {
    // non-JSON body; keep status-text fallback
  }
  return new ZigbaseError({ status: res.status, message, data, url, response: res });
}
