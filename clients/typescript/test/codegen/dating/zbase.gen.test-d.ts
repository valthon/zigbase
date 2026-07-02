import { expectTypeOf, assertType } from "vitest";
import { createClient } from "./zbase.gen.js";
import type {
  Profile, Tag, Photo, PrivatePhoto, Subscription,
  ProfileCreate, PhotoCreate, ProfileGender, SubscriptionPlan,
  DeviceLinkInitiateResp, DeviceLinkCompleteReq, DeviceLinkSession,
  Note, NoteCreate, ProfileSort,
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

// --- typed CUSTOM auth method (issue #119) ----------------------------------
async function typedCustomAuthMethod() {
  // The `device_link` custom method declares comptime I/O types, so its generated
  // surface is precise (named by the Zig type), not `Record<string, unknown>`.
  // void Initiate.Input -> initiate takes no input arg, resolves the typed result.
  const init = await zb.auth.profiles.deviceLink.initiate();
  expectTypeOf(init).toEqualTypeOf<DeviceLinkInitiateResp>();
  // complete takes the typed request and resolves the typed session.
  const done = await zb.auth.profiles.deviceLink.complete({ deviceCode: "abc" } satisfies DeviceLinkCompleteReq);
  expectTypeOf(done).toEqualTypeOf<DeviceLinkSession>();
  // @ts-expect-error initiate takes no input argument (void Initiate.Input)
  await zb.auth.profiles.deviceLink.initiate({ nope: 1 });
}

// --- relation-less collections expose the full read surface -----------------
function relationLessReadMethods() {
  // tags / subscriptions are relation-less; they must still expose iterate,
  // getFullList, and accept `sort`/`withTotal` on the page methods (these were
  // wrongly gated on hasRelations before the fix).
  expectTypeOf(zb.db.tags.iterate).toBeFunction();
  expectTypeOf(zb.db.tags.getFullList).toBeFunction();
  expectTypeOf(zb.db.subscriptions.iterate).toBeFunction();
  expectTypeOf(zb.db.subscriptions.getFullList).toBeFunction();
  // sort + withTotal typecheck on a relation-less getPage.
  void zb.db.tags.getPage({ sort: "-created", withTotal: true });
  // getFullList accepts a `sort` option on a relation-less collection.
  void zb.db.subscriptions.getFullList({ sort: "created" });
}

// --- read-method option surface (fields / signal / requestKey) --------------
async function readOptionSurface() {
  const ac = new AbortController();
  // Rich (relation-bearing) service: Photos. requestKey + signal forwarded by
  // every read method; fields forwarded by all EXCEPT getPage (the typed
  // getPage wrapper drops `fields`).
  await zb.db.photos.getOne("x", { fields: "id", signal: ac.signal, requestKey: "k" });
  await zb.db.photos.getList({ fields: "id", signal: ac.signal, requestKey: "k" });
  await zb.db.photos.getFirstListItem({ fields: "id", signal: ac.signal, requestKey: "k" });
  await zb.db.photos.getPage({ signal: ac.signal, requestKey: "k" });
  void zb.db.photos.iterate({ fields: "id", signal: ac.signal, requestKey: "k" });
  await zb.db.photos.getFullList({ fields: "id", signal: ac.signal, requestKey: "k" });

  // Relation-less service: Profiles. Same surface (minus expand).
  await zb.db.profiles.getOne("x", { fields: "id", signal: ac.signal, requestKey: "k" });
  await zb.db.profiles.getList({ fields: "id", signal: ac.signal, requestKey: "k" });
  await zb.db.profiles.getFirstListItem({ fields: "id", signal: ac.signal, requestKey: "k" });
  await zb.db.profiles.getPage({ signal: ac.signal, requestKey: "k" });
  void zb.db.profiles.iterate({ fields: "id", signal: ac.signal, requestKey: "k" });
  await zb.db.profiles.getFullList({ fields: "id", signal: ac.signal, requestKey: "k" });

  // getPage drops `fields` — the typed wrapper never forwards it, so the
  // generated surface must NOT type it (rich + relation-less branches).
  // @ts-expect-error getPage does not accept `fields`
  await zb.db.photos.getPage({ fields: "id" });
  // @ts-expect-error getPage does not accept `fields`
  await zb.db.profiles.getPage({ fields: "id" });
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

// --- search & vector gating (0.3.0) ------------------------------------------
async function searchAndVector() {
  await zb.db.messages.getList({ search: "hello world" }); // messages.body is searchable
  await zb.db.profiles.getPage({ search: "bio words" });   // search works in cursor mode
  // @ts-expect-error tags has no searchable fields -> no `search` key
  await zb.db.tags.getList({ search: "x" });
  await zb.db.subscriptions.getList({ vector: { field: "metadata", metric: "cosine", values: [0.1] } });
  // @ts-expect-error vector.field is narrowed to the collection's json fields
  await zb.db.subscriptions.getList({ vector: { field: "plan", values: [0.1] } });
  // @ts-expect-error messages has no json fields -> no `vector` key
  await zb.db.messages.getList({ vector: { field: "body", values: [1] } });
  // @ts-expect-error vector is offset-only -> absent from getPage
  await zb.db.subscriptions.getPage({ vector: { field: "metadata", values: [1] } });
}

// --- typed sort (0.3.0) -------------------------------------------------------
async function typedSort() {
  await zb.db.profiles.getList({ sort: "-age" });
  await zb.db.profiles.getList({ sort: ["-age", "created"] });
  expectTypeOf<ProfileSort>().toMatchTypeOf<string>();
  // @ts-expect-error "nope" is not a sortable field
  await zb.db.profiles.getList({ sort: "nope" });
  // @ts-expect-error json fields are not sortable
  await zb.db.subscriptions.getList({ sort: "metadata" });
}

// --- tenancy (0.3.0) ----------------------------------------------------------
function tenancyTypes() {
  // The tenant field is readable on the record...
  expectTypeOf<Note["account"]>().toEqualTypeOf<string>();
  // ...but absent from the create payload (server-stamped).
  // @ts-expect-error `account` is server-stamped; NoteCreate omits it entirely
  const bad: NoteCreate = { title: "t", account: "a1" };
  void bad;
  // withAccount returns the SAME typed client shape.
  const scoped = zb.withAccount("acct1");
  expectTypeOf(scoped).toEqualTypeOf<typeof zb>();
  void scoped.db.notes;
}

// --- abilities (0.3.0): present on EVERY generated service --------------------
async function abilities() {
  const ab = await zb.db.notes.getAbilities("n1");
  expectTypeOf(ab).toEqualTypeOf<{ view: boolean; update: boolean; delete: boolean }>();
  await zb.db.tags.getAbilities("t1", { requestKey: "ab" });
}

// --- pass-through services (0.3.0) --------------------------------------------
async function passthroughs() {
  await zb.accounts.activate("acct1");
  await zb.analytics.events({ name: "note.created", since: new Date() });
  await zb.senders.list();
}

// Reference the fns so they aren't flagged unused by the type checker.
export const _typeTests = [
  recordShapes, expandSingle, expandMulti, expandList, noExpand,
  whereOk, whereBadOperand, whereBadEnum, whereUnknownField,
  createOk, fileTyping, createMissingRequired, createRejectsUnknown, updateOmitsPassword,
  fluentOk, fluentBadEnum, fluentUnknownField,
  serviceShapes, relationLessReadMethods, readOptionSurface, fileUrlTyping,
  searchAndVector, typedSort, tenancyTypes, abilities, passthroughs,
];
