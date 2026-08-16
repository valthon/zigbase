migrate((app) => {
  app.delete(app.findCollectionByNameOrId("users"))

  const members = new Collection({
    id: "members_fixture1",
    type: "auth",
    name: "members",
    listRule: "id = @request.auth.id",
    viewRule: "id = @request.auth.id",
    updateRule: "id = @request.auth.id",
    deleteRule: "id = @request.auth.id",
    fields: [
      { id: "member_name_001", name: "name", type: "text", required: true },
      { id: "member_avatar01", name: "avatar", type: "file", maxSelect: 1 },
      { id: "member_created1", name: "created", type: "autodate", onCreate: true },
      { id: "member_updated1", name: "updated", type: "autodate", onCreate: true, onUpdate: true },
    ],
    passwordAuth: { enabled: true, identityFields: ["email"] },
  })
  app.save(members)

  const posts = new Collection({
    id: "posts_fixture001",
    type: "base",
    name: "posts",
    listRule: "",
    viewRule: "",
    createRule: "@request.auth.id != ''",
    updateRule: "owner = @request.auth.id",
    deleteRule: "owner = @request.auth.id",
    fields: [
      { id: "post_title_0001", name: "title", type: "text", required: true },
      { id: "post_owner_0001", name: "owner", type: "relation", collectionId: members.id, maxSelect: 1, required: true },
      { id: "post_cover_0001", name: "cover", type: "file", maxSelect: 1 },
      { id: "post_gallery_01", name: "gallery", type: "file", maxSelect: 3 },
      { id: "post_created_01", name: "created", type: "autodate", onCreate: true },
      { id: "post_updated_01", name: "updated", type: "autodate", onCreate: true, onUpdate: true },
    ],
  })
  app.save(posts)
  posts.fields.add(new RelationField({
    id: "post_related_01",
    name: "related",
    collectionId: posts.id,
    maxSelect: 3,
  }))
  app.save(posts)

  const secrets = new Collection({
    id: "secrets_fixture1",
    type: "base",
    name: "secrets",
    listRule: "owner = @request.auth.id",
    viewRule: "owner = @request.auth.id",
    createRule: "@request.auth.id != ''",
    updateRule: "owner = @request.auth.id",
    deleteRule: "owner = @request.auth.id",
    fields: [
      { id: "secret_owner_01", name: "owner", type: "relation", collectionId: members.id, maxSelect: 1, required: true },
      { id: "secret_document", name: "document", type: "file", maxSelect: 1, protected: true },
      { id: "secret_created1", name: "created", type: "autodate", onCreate: true },
      { id: "secret_updated1", name: "updated", type: "autodate", onCreate: true, onUpdate: true },
    ],
  })
  app.save(secrets)

  const member = new Record(members)
  member.id = "member000000001"
  member.set("email", "ada@example.test")
  member.set("password", "migrated-secret")
  member.set("passwordConfirm", "migrated-secret")
  member.set("verified", true)
  member.set("name", "Ada")
  member.set("avatar", $filesystem.fileFromBytes("AVATAR", "avatar.txt"))
  app.save(member)

  const first = new Record(posts)
  first.id = "post00000000001"
  first.set("title", "Public first")
  first.set("owner", member.id)
  first.set("cover", $filesystem.fileFromBytes("PUBLIC-COVER", "cover.txt"))
  first.set("gallery", [
    $filesystem.fileFromBytes("GALLERY-A", "a.txt"),
    $filesystem.fileFromBytes("GALLERY-B", "b.txt"),
  ])
  app.save(first)

  const second = new Record(posts)
  second.id = "post00000000002"
  second.set("title", "Public second")
  second.set("owner", member.id)
  second.set("related", [first.id])
  app.save(second)
  first.set("related", [second.id])
  app.save(first)

  const secret = new Record(secrets)
  secret.id = "secret000000001"
  secret.set("owner", member.id)
  secret.set("document", $filesystem.fileFromBytes("PRIVATE-DOCUMENT", "secret.txt"))
  app.save(secret)
}, (app) => {})
