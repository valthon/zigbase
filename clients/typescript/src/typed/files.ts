import type { FilesService, FileRecordRef, FileUrlOptions } from "../files.js";

/**
 * Broad runtime shape of the typed files helper. The generated file casts this
 * so `filename` is typed to the record's collection file fields.
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
