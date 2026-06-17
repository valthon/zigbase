import { expectTypeOf } from "vitest";
import type { WithExpand } from "../../src/typed/expand.js";
import type {
  StringOps,
  NumberOps,
  EnumOps,
  RelOps,
} from "../../src/typed/operators.js";

interface User {
  id: string;
  name: string;
}
interface Tag {
  id: string;
  label: string;
}
interface Post {
  id: string;
  title: string;
  author: string;
  tags: string[];
}
type PostRelations = { author: User; tags: Tag[] };

// Single relation narrows to the record.
expectTypeOf<WithExpand<Post, PostRelations, "author">>().toEqualTypeOf<
  Post & { expand: { author: User } }
>();

// Multi relation narrows to an array.
expectTypeOf<WithExpand<Post, PostRelations, "tags">>().toEqualTypeOf<
  Post & { expand: { tags: Tag[] } }
>();

// No expand -> empty expand object; the relation key is NOT present.
type NoExpand = WithExpand<Post, PostRelations, never>;
// @ts-expect-error author is not in the expand object when not requested
const _bad: NoExpand["expand"]["author"] = undefined as unknown as User;

// Operator shapes are optional-key objects.
expectTypeOf<StringOps["like"]>().toEqualTypeOf<string | undefined>();
expectTypeOf<NumberOps["gte"]>().toEqualTypeOf<number | undefined>();
expectTypeOf<EnumOps<"a" | "b">["in"]>().toEqualTypeOf<("a" | "b")[] | undefined>();
expectTypeOf<RelOps["in"]>().toEqualTypeOf<string[] | undefined>();
