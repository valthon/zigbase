import 'package:test/test.dart';
import 'package:zigbase_client/typed.dart';

enum Status {
  draft('draft'),
  published('published');

  const Status(this.wire);
  final String wire;
}

// A minimal generated-style fields builder for a `posts` collection with a
// nested `author` relation to `users`.
class UserFields {
  UserFields([this.prefix = '']);
  final String prefix;
  StringFieldExpr get name => StringFieldExpr('${prefix}name');
  NumFieldExpr get age => NumFieldExpr('${prefix}age');
}

class PostFields {
  PostFields([this.prefix = '']);
  final String prefix;
  StringFieldExpr get title => StringFieldExpr('${prefix}title');
  EnumFieldExpr<Status> get status =>
      EnumFieldExpr('${prefix}status', (e) => e.wire);
  NumFieldExpr get price => NumFieldExpr('${prefix}price');
  BoolFieldExpr get active => BoolFieldExpr('${prefix}active');
  RelFieldExpr<UserFields> get author =>
      RelFieldExpr('${prefix}author', (p) => UserFields(p));
}

void main() {
  final f = PostFields();

  group('scalar operators', () {
    test('string comparisons + pattern match', () {
      expect(f.title.eq('hi').compile(), "title = 'hi'");
      expect(f.title.neq('hi').compile(), "title != 'hi'");
      expect(f.title.like('foo').compile(), 'title ~ \'foo\'');
      expect(f.title.nlike('foo').compile(), "title !~ 'foo'");
    });

    test('number comparisons', () {
      expect(f.price.gte(10).compile(), 'price >= 10');
      expect(f.price.lt(2.5).compile(), 'price < 2.5');
    });

    test('bool eq', () {
      expect(f.active.eq(true).compile(), 'active = true');
    });
  });

  group('enum fields serialize to wire strings', () {
    test('eq / neq / inList', () {
      expect(f.status.eq(Status.published).compile(), "status = 'published'");
      expect(f.status.neq(Status.draft).compile(), "status != 'draft'");
      expect(
        f.status.inList([Status.draft, Status.published]).compile(),
        "status in ('draft', 'published')",
      );
    });
  });

  group('inList', () {
    test('non-empty', () {
      expect(f.title.inList(['a', 'b']).compile(), "title in ('a', 'b')");
    });
    test('empty list emits constant-false form', () {
      expect(f.title.inList(<String>[]).compile(), 'title in ()');
    });
  });

  group('and / or parenthesize', () {
    test('and', () {
      final e = f.price.gte(10).and(f.status.eq(Status.published));
      expect(e.compile(), "(price >= 10 && status = 'published')");
    });
    test('or', () {
      final e = f.title.eq('a').or(f.title.eq('b'));
      expect(e.compile(), "(title = 'a' || title = 'b')");
    });
  });

  group('relation fields', () {
    test('id-level eq', () {
      expect(f.author.eq('u1').compile(), "author = 'u1'");
    });
    test('nested relation where builds dotted path', () {
      expect(f.author.rel((u) => u.name.like('Ann')).compile(),
          "author.name ~ 'Ann'");
      expect(f.author.rel((u) => u.age.gt(21)).compile(), 'author.age > 21');
    });
  });

  test('injection-safe escaping of quotes', () {
    expect(f.title.eq("O'Brien").compile(), "title = 'O\\'Brien'");
  });
}
