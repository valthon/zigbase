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

export type _Types = [Profile, Photo, Message, Subscription];
