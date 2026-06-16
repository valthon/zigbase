import type { Transport } from "./transport.js";

/** Minimal record shape `getUrl` can derive a collection + id from. */
export interface FileRecordRef {
  id: string;
  collectionId?: string;
  collectionName?: string;
}

export interface FileUrlOptions {
  download?: boolean;
  token?: string;
  thumb?: string;
}

export class FilesService {
  constructor(
    private readonly transport: Transport,
    private readonly baseUrl: string,
  ) {}

  /**
   * Build a file URL. Either pass a record object + filename, or explicit
   * (collectionIdOrName, recordId, filename). Optional query params: download/token/thumb.
   *
   *   files.getUrl(record, "photo.png", { thumb: "100x100" })
   *   files.getUrl("posts", "rec1", "photo.png")
   */
  getUrl(record: FileRecordRef, filename: string, opts?: FileUrlOptions): string;
  getUrl(collectionIdOrName: string, recordId: string, filename: string, opts?: FileUrlOptions): string;
  getUrl(
    a: FileRecordRef | string,
    b: string,
    c?: string | FileUrlOptions,
    d?: FileUrlOptions,
  ): string {
    let col: string;
    let rec: string;
    let filename: string;
    let opts: FileUrlOptions | undefined;

    if (typeof a === "string") {
      col = a;
      rec = b;
      filename = c as string;
      opts = d;
    } else {
      col = a.collectionId ?? a.collectionName ?? "";
      rec = a.id;
      filename = b;
      opts = c as FileUrlOptions | undefined;
    }

    const base = this.baseUrl.replace(/\/+$/, "");
    let url =
      `${base}/api/files/${encodeURIComponent(col)}/${encodeURIComponent(rec)}/` +
      encodeURIComponent(filename);

    const params = new URLSearchParams();
    if (opts?.download) params.set("download", "1");
    if (opts?.thumb) params.set("thumb", opts.thumb);
    if (opts?.token) params.set("token", opts.token);
    const qs = params.toString();
    if (qs) url += `?${qs}`;
    return url;
  }

  /** Mint a short-lived file-access token for embedding protected files. */
  async getToken(): Promise<string> {
    const res = await this.transport.send<{ token: string }>("/api/files/token", {
      method: "POST",
    });
    return res.token;
  }
}
