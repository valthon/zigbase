// ---- AST -------------------------------------------------------------------

export type CompareOp = "=" | "!=" | ">" | ">=" | "<" | "<=" | "~" | "!~";
export type Literal = string | number | boolean | null;

export interface CompareNode {
  kind: "compare";
  path: string[];
  op: CompareOp;
  value: Literal;
}

export interface LogicNode {
  kind: "and" | "or";
  left: FilterNode;
  right: FilterNode;
}

export type FilterNode = CompareNode | LogicNode;

// ---- tokenizer -------------------------------------------------------------

type Token =
  | { t: "field"; v: string }
  | { t: "op"; v: CompareOp }
  | { t: "and" }
  | { t: "or" }
  | { t: "lparen" }
  | { t: "rparen" }
  | { t: "lit"; v: Literal };

const OP_CHARS = new Set(["=", "!", ">", "<", "~"]);

function tokenize(input: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  const n = input.length;
  while (i < n) {
    const c = input[i]!;
    if (c === " " || c === "\t" || c === "\n") {
      i += 1;
      continue;
    }
    if (c === "(") {
      tokens.push({ t: "lparen" });
      i += 1;
      continue;
    }
    if (c === ")") {
      tokens.push({ t: "rparen" });
      i += 1;
      continue;
    }
    if (c === "&" && input[i + 1] === "&") {
      tokens.push({ t: "and" });
      i += 2;
      continue;
    }
    if (c === "|" && input[i + 1] === "|") {
      tokens.push({ t: "or" });
      i += 2;
      continue;
    }
    if (c === "'" || c === '"') {
      const quote = c;
      let j = i + 1;
      let str = "";
      while (j < n && input[j] !== quote) {
        if (input[j] === "\\" && j + 1 < n) {
          str += input[j + 1];
          j += 2;
        } else {
          str += input[j];
          j += 1;
        }
      }
      tokens.push({ t: "lit", v: str });
      i = j + 1;
      continue;
    }
    if (OP_CHARS.has(c)) {
      // Longest-match the operators.
      const two = input.slice(i, i + 2);
      if (two === "!=" || two === ">=" || two === "<=" || two === "!~") {
        tokens.push({ t: "op", v: two as CompareOp });
        i += 2;
        continue;
      }
      if (c === "=" || c === ">" || c === "<" || c === "~") {
        tokens.push({ t: "op", v: c as CompareOp });
        i += 1;
        continue;
      }
      throw new Error(`unexpected operator near "${input.slice(i)}"`);
    }
    // bareword: number, bool, null, or a (dotted) field path.
    let j = i;
    while (j < n && !" \t\n()&|=!<>~'\"".includes(input[j]!)) j += 1;
    const word = input.slice(i, j);
    i = j;
    if (word === "true") tokens.push({ t: "lit", v: true });
    else if (word === "false") tokens.push({ t: "lit", v: false });
    else if (word === "null") tokens.push({ t: "lit", v: null });
    else if (/^-?\d+(\.\d+)?$/.test(word)) tokens.push({ t: "lit", v: Number(word) });
    else tokens.push({ t: "field", v: word });
  }
  return tokens;
}

// ---- parser (precedence: || lowest, then &&, then comparisons / parens) -----

class Parser {
  private pos = 0;
  constructor(private readonly tokens: Token[]) {}

  parse(): FilterNode {
    const node = this.parseOr();
    if (this.pos !== this.tokens.length) throw new Error("trailing tokens in filter");
    return node;
  }

  private peek(): Token | undefined {
    return this.tokens[this.pos];
  }

  private next(): Token {
    const tok = this.tokens[this.pos];
    if (!tok) throw new Error("unexpected end of filter");
    this.pos += 1;
    return tok;
  }

  private parseOr(): FilterNode {
    let left = this.parseAnd();
    while (this.peek()?.t === "or") {
      this.next();
      left = { kind: "or", left, right: this.parseAnd() };
    }
    return left;
  }

  private parseAnd(): FilterNode {
    let left = this.parsePrimary();
    while (this.peek()?.t === "and") {
      this.next();
      left = { kind: "and", left, right: this.parsePrimary() };
    }
    return left;
  }

  private parsePrimary(): FilterNode {
    const tok = this.peek();
    if (tok?.t === "lparen") {
      this.next();
      const node = this.parseOr();
      const close = this.next();
      if (close.t !== "rparen") throw new Error("expected )");
      return node;
    }
    return this.parseCompare();
  }

  private parseCompare(): CompareNode {
    const field = this.next();
    if (field.t !== "field") throw new Error("expected a field path");
    const op = this.next();
    if (op.t !== "op") throw new Error("expected a comparison operator");
    const lit = this.next();
    if (lit.t !== "lit") throw new Error("expected a literal value");
    return { kind: "compare", path: field.v.split("."), op: op.v, value: lit.v };
  }
}

export function parseFilter(input: string): FilterNode {
  return new Parser(tokenize(input)).parse();
}

// ---- evaluator -------------------------------------------------------------

function resolvePath(record: Record<string, unknown>, path: string[]): unknown {
  let cur: unknown = record;
  for (const key of path) {
    if (cur === null || cur === undefined || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[key];
  }
  return cur;
}

function compare(actual: unknown, op: CompareOp, expected: Literal): boolean {
  switch (op) {
    case "=":
      return actual === expected;
    case "!=":
      return actual !== expected;
    case ">":
      return (actual as number) > (expected as number);
    case ">=":
      return (actual as number) >= (expected as number);
    case "<":
      return (actual as number) < (expected as number);
    case "<=":
      return (actual as number) <= (expected as number);
    case "~":
      return typeof actual === "string" && actual.includes(String(expected));
    case "!~":
      return !(typeof actual === "string" && actual.includes(String(expected)));
  }
}

export function evaluateFilter(record: Record<string, unknown>, node: FilterNode): boolean {
  if (node.kind === "and") {
    return evaluateFilter(record, node.left) && evaluateFilter(record, node.right);
  }
  if (node.kind === "or") {
    return evaluateFilter(record, node.left) || evaluateFilter(record, node.right);
  }
  return compare(resolvePath(record, node.path), node.op, node.value);
}
