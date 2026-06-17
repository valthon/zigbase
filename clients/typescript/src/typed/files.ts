import type { FilesService, FileRecordRef, FileUrlOptions } from "../files.js";

/**
 * Broad runtime shape of the typed files helper. The generated file casts this
 * so `field` is typed to the record's collection file fields.
 */
export interface RawTypedFiles {
  fileUrl(record: FileRecordRef, field: string, opts?: FileUrlOptions): string;
}

export function makeTypedFiles(files: FilesService): RawTypedFiles {
  return {
    fileUrl(record, field, opts) {
      return files.getUrl(record, field, opts);
    },
  };
}
