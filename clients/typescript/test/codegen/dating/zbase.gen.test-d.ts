import { expectTypeOf, assertType } from "vitest";
import { createClient } from "./zbase.gen.js";
import type {
  Profile, Tag, Photo, PrivatePhoto, Subscription,
  ProfileCreate, PhotoCreate, ProfileGender, SubscriptionPlan,
} from "./zbase.gen.js";

const zb = createClient("http://api.test", { WebSocket: globalThis.WebSocket });

// --- field -> TS mapping -----------------------------------------------------
function recordShapes() {
  expectTypeOf<Profile["age"]>().toEqualTypeOf<number>();        // number
  expectTypeOf<Profile["website"]>().toEqualTypeOf<string>();    // url -> string
  expectTypeOf<Profile["gender"]>().toEqualTypeOf<ProfileGender>(); // select union
  expectTypeOf<Profile["avatar"]>().toEqualTypeOf<string>();     // file -> filename
  expectTypeOf<Photo["tags"]>().toEqualTypeOf<string[]>();       // multi relation -> string[]
  expectTypeOf<Photo["owner"]>().toEqualTypeOf<string>();        // single relation -> id
  expectTypeOf<Subscription["metadata"]>().toEqualTypeOf<unknown>(); // json -> unknown
  expectTypeOf<Subscription["active"]>().toEqualTypeOf<boolean>(); // bool
  expectTypeOf<ProfileGender>().toEqualTypeOf<"female" | "male" | "nonbinary" | "other">();
  expectTypeOf<SubscriptionPlan>().toEqualTypeOf<"free" | "plus" | "premium">();
}

// --- expand narrowing (single + multi) --------------------------------------
async function expandSingle() {
  const p = await zb.db.photos.getOne("x", { expand: ["owner"] });
  expectTypeOf(p.expand.owner).toEqualTypeOf<Profile>();
}
async function expandMulti() {
  const p = await zb.db.photos.getOne("x", { expand: ["tags"] });
  expectTypeOf(p.expand.tags).toEqualTypeOf<Tag[]>();
}
async function expandList() {
  const r = await zb.db.photos.getList({ expand: ["owner"] });
  expectTypeOf(r.items[0]!.expand.owner).toEqualTypeOf<Profile>();
}
async function noExpand() {
  const p = await zb.db.photos.getOne("x");
  // @ts-expect-error owner was not expanded
  p.expand.owner;
}

// --- where: operators, nested relation, AND/OR ------------------------------
async function whereOk() {
  await zb.db.profiles.getList({ where: { age: { gte: 18 }, gender: "female" } });
  await zb.db.photos.getList({ where: { owner: { name: { like: "An" } } } }); // nested relation
  await zb.db.profiles.getList({ where: { AND: [{ age: { gt: 18 } }, { verified: true }] } });
  await zb.db.profiles.getList({ where: { OR: [{ name: { like: "a" } }, { name: { like: "b" } }] } });
}
async function whereBadOperand() {
  // @ts-expect-error age expects number/NumberOps, not a string
  await zb.db.profiles.getList({ where: { age: "old" } });
}
async function whereBadEnum() {
  // @ts-expect-error 'unknown' is not a ProfileGender
  await zb.db.profiles.getList({ where: { gender: "unknown" } });
}
async function whereUnknownField() {
  // @ts-expect-error `nope` is not a field
  await zb.db.profiles.getList({ where: { nope: 1 } });
}

// --- create/update ----------------------------------------------------------
async function createOk() {
  await zb.db.profiles.create({ email: "a@b.c", password: "p", passwordConfirm: "p" });
  await zb.db.photos.create({ owner: "id1", caption: "hi" });
}
function fileTyping() {
  // file field is File | Blob on create.
  assertType<PhotoCreate>({ image: new Blob([]) });
  assertType<ProfileCreate>({ email: "a@b.c", password: "p", passwordConfirm: "p", avatar: new Blob([]) });
}
async function createMissingRequired() {
  // @ts-expect-error email/password/passwordConfirm are required on an auth create
  await zb.db.profiles.create({ name: "x" });
}
async function createRejectsUnknown() {
  // @ts-expect-error `slug` is not a ProfileCreate field
  await zb.db.profiles.create({ email: "a@b.c", password: "p", passwordConfirm: "p", slug: "x" });
}
function updateOmitsPassword() {
  // ProfileUpdate = Partial<Omit<ProfileCreate, password|passwordConfirm>> -> password not allowed.
  // @ts-expect-error password cannot be patched via update
  assertType<Parameters<typeof zb.db.profiles.update>[1]>({ password: "p" });
}

// --- fluent builder ---------------------------------------------------------
function fluentOk() {
  return zb.db.profiles.filter((f) => f.age.gte(18).and(f.gender.eq("female")));
}
function fluentBadEnum() {
  // @ts-expect-error 'unknown' is not a ProfileGender operand
  return zb.db.profiles.filter((f) => f.gender.eq("unknown"));
}
function fluentUnknownField() {
  // @ts-expect-error `nope` is not a fields accessor
  return zb.db.profiles.filter((f) => f.nope.eq("x"));
}

// --- service signatures + realtime alias ------------------------------------
function serviceShapes() {
  // Methods confirmed against the generated ProfilesService surface.
  expectTypeOf(zb.db.profiles.authWithPassword).toBeFunction();
  expectTypeOf(zb.db.profiles.getPage).toBeFunction();
  expectTypeOf(zb.db.profiles.getFirstListItem).toBeFunction();
  // realtime alias exists per collection.
  expectTypeOf(zb.realtime.photos.subscribe).toBeFunction();
}

// --- per-collection fileUrl typing (single-value only) ----------------------
function fileUrlTyping() {
  const profile = {} as Profile;
  // ProfileFileField is "avatar"; fileUrl accepts it.
  zb.db.profiles.fileUrl(profile, "avatar");
  // @ts-expect-error "name" is not a file field
  zb.db.profiles.fileUrl(profile, "name");
  const priv = {} as PrivatePhoto;
  zb.db.privatePhotos.fileUrl(priv, "image");
}

// Reference the fns so they aren't flagged unused by the type checker.
export const _typeTests = [
  recordShapes, expandSingle, expandMulti, expandList, noExpand,
  whereOk, whereBadOperand, whereBadEnum, whereUnknownField,
  createOk, fileTyping, createMissingRequired, createRejectsUnknown, updateOmitsPassword,
  fluentOk, fluentBadEnum, fluentUnknownField,
  serviceShapes, fileUrlTyping,
];
