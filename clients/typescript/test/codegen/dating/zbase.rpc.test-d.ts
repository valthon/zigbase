import { expectTypeOf } from "vitest";
import { createClient } from "./zbase.gen.js";
import type {
  SendWinkIn,
  SendWinkOut,
  SearchIn,
  SearchOut,
} from "./zbase.gen.js";

const zb = createClient("http://api.test", { WebSocket: globalThis.WebSocket });

// --- positives ---

// echoPing: path param + struct output
function rpcEchoPing() {
  const p1: Promise<SendWinkOut> = zb.rpc.echoPing({ id: "abc" });
  void p1;
  expectTypeOf(p1).toEqualTypeOf<Promise<{ ok: boolean; note: string }>>();
}

// winksSend: POST body input (nested enum/optional/array) + struct output
function rpcWinksSend() {
  const p2: Promise<SendWinkOut> = zb.rpc.winksSend({
    note: "hi",
    color: "red",
    sticker: null,
    tags: ["a", "b"],
  });
  void p2;
  expectTypeOf(p2).toEqualTypeOf<Promise<{ ok: boolean; note: string }>>();
}

// messagesSearch: GET query input + struct output
function rpcMessagesSearch() {
  const p3: Promise<SearchOut> = zb.rpc.messagesSearch({ q: "x", limit: 5, sort: "newest" });
  void p3;
  expectTypeOf(p3).toEqualTypeOf<Promise<{ count: number }>>();
}

// winksStatus: no input arg, void output
function rpcWinksStatus() {
  const p4: Promise<void> = zb.rpc.winksStatus();
  void p4;
  expectTypeOf(p4).toEqualTypeOf<Promise<void>>();
}

// winksRaw: no input arg, unknown output
function rpcWinksRaw() {
  const p5: Promise<unknown> = zb.rpc.winksRaw();
  void p5;
  expectTypeOf(p5).toEqualTypeOf<Promise<unknown>>();
}

// --- negatives ---

function rpcNegatives() {
  // @ts-expect-error "purple" is not a valid Color enum literal
  zb.rpc.winksSend({ note: "x", color: "purple", sticker: null, tags: [] });

  // @ts-expect-error "random" is not a valid SearchSort literal
  zb.rpc.messagesSearch({ q: "x", limit: 1, sort: "random" });

  // @ts-expect-error echoPing requires { id: string }; empty object is missing `id`
  zb.rpc.echoPing({});

  // @ts-expect-error messagesSearch requires `q`, `limit`, and `sort`; `q` is missing
  zb.rpc.messagesSearch({ limit: 1, sort: "newest" });

  // @ts-expect-error winksStatus takes no input object; { foo: 1 } has excess property `foo` not in SendOptions
  zb.rpc.winksStatus({ foo: 1 });
}

// Reference all test fns so they aren't flagged unused by the type checker.
export const _typeTests = [
  rpcEchoPing, rpcWinksSend, rpcMessagesSearch, rpcWinksStatus, rpcWinksRaw,
  rpcNegatives,
];
