// Exercises the generated dating client against @zigbase/client/typed so
// `tsc --noEmit` proves the emitted file typechecks. Plan 2 adds the deep
// *.test-d.ts expand/where/create/fluent assertions + real-binary e2e.
import { createClient } from "./zbase.gen.js";
import type {
  Profile,
  Photo,
  Message,
  Subscription,
  ProfileCreate,
  PhotoWhere,
  TagWhere,
} from "./zbase.gen.js";

export function _smoke() {
  const zb = createClient("http://api.test");
  // db surface is present + typed
  void zb.db.profiles;
  void zb.db.photos;
  void zb.realtime.messages;
  // representative types resolve
  const _p: ProfileCreate = { email: "a@b.c", password: "x".repeat(8), passwordConfirm: "x".repeat(8) };
  const _w: PhotoWhere = { visibility: "public" };
  return { _p, _w } as { _p: ProfileCreate; _w: PhotoWhere };
}

// Fix A: per-collection fileUrl — the method lives on each file-bearing service,
// typed to that collection's record + its own FileField union.
export function _fileUrlSmoke(zb: ReturnType<typeof createClient>, profile: Profile, photo: Photo) {
  // Profiles has an avatar field; Photos has an image field.
  const _avatarUrl: string = zb.db.profiles.fileUrl(profile, "avatar");
  const _imageUrl: string = zb.db.photos.fileUrl(photo, "image", { thumb: "100x100" });
  return { _avatarUrl, _imageUrl };
}

// Fix B: system fields (id/created/updated) now appear in Where and Fields
// so they typecheck in getList / filter calls.
// Note: created/updated emit as StringOps | string (autodate maps to string),
// so we use the StringOps operators (eq/neq/like/in) or pass a raw string.
export function _systemFieldSmoke(zb: ReturnType<typeof createClient>) {
  // id/created/updated are filterable in Where types (string or StringOps).
  const _wCreated: TagWhere = { created: "2020-01-01" };
  const _wId: TagWhere = { id: "abc123" };
  const _wUpdated: PhotoWhere = { updated: { eq: "2025-01-01" } };

  // getList with system-field where — must typecheck.
  void zb.db.tags.getList({ where: { created: "2024-01-01" } });
  void zb.db.photos.getList({ where: { updated: { eq: "2025-01-01" } } });
  void zb.db.tags.getList({ where: { id: { eq: "rec123" } } });

  // filter/fluent builder — Fields interface now has id/created/updated.
  const _filterStr: string = zb.db.tags.filter((f) => f.created.eq("2024-01-01"));
  const _filterUpdated: string = zb.db.messages.filter((f) => f.updated.neq("2025-01-01"));
  const _filterId: string = zb.db.subscriptions.filter((f) => f.id.eq("rec123"));

  return { _wCreated, _wId, _wUpdated, _filterStr, _filterUpdated, _filterId };
}

export type _Types = [Profile, Photo, Message, Subscription];
