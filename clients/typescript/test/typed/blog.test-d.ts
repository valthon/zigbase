import { expectTypeOf, assertType } from "vitest";
import { createClient } from "../fixtures/blog.gen.js";
import type {
  Post,
  User,
  Tag,
  PostCreate,
} from "../fixtures/blog.gen.js";

const zb = createClient("http://api.test");

// --- expand narrowing ------------------------------------------------------

// getOne with expand:['author'] -> Post & { expand: { author: User } }
async function expandOne() {
  const p = await zb.db.posts.getOne("p1", { expand: ["author"] });
  expectTypeOf(p.expand.author).toEqualTypeOf<User>();
  expectTypeOf(p.title).toEqualTypeOf<string>();
}

// getOne with expand:['tags'] -> tags: Tag[]
async function expandTags() {
  const p = await zb.db.posts.getOne("p1", { expand: ["tags"] });
  expectTypeOf(p.expand.tags).toEqualTypeOf<Tag[]>();
}

// No expand -> reading a relation off `expand` is an error.
async function noExpand() {
  const p = await zb.db.posts.getOne("p1");
  // @ts-expect-error author was not expanded
  p.expand.author;
}

// getList narrows the item type the same way.
async function expandList() {
  const res = await zb.db.posts.getList({ expand: ["author"] });
  expectTypeOf(res.items[0]!.expand.author).toEqualTypeOf<User>();
}

// --- where: operand + unknown-field rejection ------------------------------

async function whereOk() {
  await zb.db.posts.getList({ where: { status: "published", price: { gte: 5 } } });
  await zb.db.posts.getList({ where: { author: { name: { like: "A" } } } }); // nested
}

async function whereBadOperand() {
  // @ts-expect-error price expects a number/NumberOps, not a string
  await zb.db.posts.getList({ where: { price: "lots" } });
}

async function whereBadEnum() {
  // @ts-expect-error 'archived' is not a PostStatus
  await zb.db.posts.getList({ where: { status: "archived" } });
}

async function whereUnknownField() {
  // @ts-expect-error `nope` is not a field of PostWhere
  await zb.db.posts.getList({ where: { nope: 1 } });
}

// --- create: required + unknown rejection ----------------------------------

async function createOk() {
  await zb.db.posts.create({ title: "Hi", status: "draft" });
}

async function createMissingRequired() {
  // @ts-expect-error title is required
  await zb.db.posts.create({ status: "draft" });
}

async function createUnknownField() {
  // @ts-expect-error `slug` is not a PostCreate field
  await zb.db.posts.create({ title: "Hi", slug: "hi" });
}

assertType<PostCreate>({ title: "Hi" });

async function createRejectsId() {
  // @ts-expect-error id is not a PostCreate field (excess property)
  await zb.db.posts.create({ title: "Hi", id: "override" });
}

async function getListPaging() {
  await zb.db.posts.getList({ page: 1, limit: 5, where: { status: "published" } });
}

// --- fluent: enum operand rejection ----------------------------------------

function fluentOk() {
  return zb.db.posts.filter((f) => f.status.eq("published").or(f.price.gte(10)));
}

// The fluent accessor only exposes the collection's fields.
function fluentUnknownField() {
  return zb.db.posts.filter((f) =>
    // @ts-expect-error `slug` is not a PostFields accessor
    f.slug.eq("x"),
  );
}

// Per-field operand typing via TypedFieldExpr<V>: non-enum values error.
function fluentBadEnum() {
  // @ts-expect-error 'archived' is not a PostStatus operand
  return zb.db.posts.filter((f) => f.status.eq("archived"));
}

// --- files: file-field typing ----------------------------------------------

function filesOk(p: Post) {
  zb.files.url(p, "cover");
}

function filesBadField(p: Post) {
  // @ts-expect-error 'title' is not a file field
  zb.files.url(p, "title");
}

// --- getPage returns a typed CursorPage ------------------------------------

async function pageTyped() {
  const page = await zb.db.posts.getPage({ where: { status: "published" }, limit: 10 });
  expectTypeOf(page.items).toEqualTypeOf<Post[]>();
  expectTypeOf(page.nextCursor).toEqualTypeOf<string | null>();
}

// --- iterate and getFullList return the right types -------------------------

async function iterateTyped() {
  // SP1's iterate returns AsyncIterableIterator<T>; the fixture declares Post.
  const iter = zb.db.posts.iterate({ where: { status: "published" } });
  expectTypeOf(iter).toEqualTypeOf<AsyncIterableIterator<Post>>();
}

async function getFullListTyped() {
  const items = await zb.db.posts.getFullList({ where: { status: "published" } });
  expectTypeOf(items).toEqualTypeOf<Post[]>();
}

// --- realtime: getList expand accepts string[] (Fix 3) -----------------------

// getList should accept expand as string[] (consistent with TypedLiveListOptions
// and other typed surfaces). Previously the interface declared `expand?: string`.
async function realtimeGetListExpandArray() {
  // This must compile: expand is string[], not string.
  await zb.realtime.posts.getList({ expand: ["author"] });
}

async function realtimeGetListExpandArrayMulti() {
  await zb.realtime.posts.getList({ expand: ["author", "tags"] });
}

// --- create/update with opts (Fix 4) -----------------------------------------

// create and update should accept an opts bag with expand/fields/signal/requestKey.
async function createWithExpandOpts() {
  const post = await zb.db.posts.create(
    { title: "Hi", status: "draft" },
    { expand: ["author"] },
  );
  // expand: ['author'] should narrow the return type
  expectTypeOf(post.expand.author).toEqualTypeOf<User>();
}

async function updateWithExpandOpts() {
  const post = await zb.db.posts.update(
    "p1",
    { title: "Updated" },
    { expand: ["tags"] },
  );
  expectTypeOf(post.expand.tags).toEqualTypeOf<Tag[]>();
}

async function createNoOpts() {
  const post = await zb.db.posts.create({ title: "Hi" });
  // no expand -> expand property is not accessible
  // @ts-expect-error author was not expanded
  post.expand.author;
}

// Reference the fns so they aren't flagged unused by the type checker.
export const _typeTests = [
  expandOne, expandTags, noExpand, expandList,
  whereOk, whereBadOperand, whereBadEnum, whereUnknownField,
  createOk, createMissingRequired, createUnknownField, createRejectsId,
  getListPaging,
  fluentOk, fluentUnknownField, fluentBadEnum, filesOk, filesBadField, pageTyped,
  iterateTyped, getFullListTyped,
  realtimeGetListExpandArray, realtimeGetListExpandArrayMulti,
  createWithExpandOpts, updateWithExpandOpts, createNoOpts,
];
