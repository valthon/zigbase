import type { FilesService, FileRecordRef, FileUrlOptions } from "../files.js";

/**
 * Broad runtime shape of the typed files helper. This low-level interface
 * takes the stored filename directly (e.g. `record['cover']`); the generated
 * concrete wrapper is what types the field name and does the `record[field]`
 * lookup before calling this.
 */
export interface RawTypedFiles {
  /**
   * Low-level: pass the STORED filename (e.g. `record['cover']`); the
   * generated concrete wrapper (Task 9) does the `record[field]` lookup and
   * calls this with the resulting filename.
   */
  fileUrl(record: FileRecordRef, filename: string, opts?: FileUrlOptions): string;
}

export function makeTypedFiles(files: FilesService): RawTypedFiles {
  return {
    fileUrl(record, filename, opts) {
      return files.getUrl(record, filename, opts);
    },
  };
}
