/**
 * The single generic of the typed core. Narrows a record's type by the typed
 * `expand` keys actually requested at the call site.
 *
 * `Relations` is baked by the generator per collection: single relations map to
 * the related record (`{ author: User }`), multi-relations to an array
 * (`{ tags: Tag[] }`). `K` is the union of expand keys passed to the call
 * (defaulting to `never`, i.e. no expand).
 *
 *   WithExpand<Post, { author: User; tags: Tag[] }, 'author'>
 *     => Post & { expand: { author: User } }
 *   WithExpand<Post, { author: User; tags: Tag[] }, 'tags'>
 *     => Post & { expand: { tags: Tag[] } }
 *   WithExpand<Post, …, never>  => Post & { expand: {} }
 *
 * Only the first level narrows; deeper dotted expands pass through as strings
 * (out of scope — see the spec's "Out of scope").
 */
export type WithExpand<
  Rec,
  Relations,
  K extends keyof Relations,
> = Rec & { expand: { [P in K]: Relations[P] } };
