---
title: Realtime broadcast
description: Pushing to custom WebSocket channels from routes and jobs — signal vs broadcast, and gating subscriptions with canSubscribe.
order: 8
group: features
---

# Realtime broadcast

Beyond record subscriptions, `ctx.realtime()` lets a route or a background job publish its own
events on custom (non-record) channels over the same WebSocket the record subscriptions use. This
guide covers the signal-vs-broadcast contract, gating who may subscribe to a custom topic, and
subscribing from the client.

## Beyond record subscriptions

The realtime layer auto-publishes record-change events on `<collection>` / `<collection>/<id>`
topics — that path needs no code. `ctx.realtime()` is for everything else: a handler — a route
**or** a background job — can publish its own events on **custom** (non-record) channels, using
the same subscribe/unsubscribe protocol clients already use. Both publish entry points are a
**no-op when the realtime reactor isn't running** (tests/CLI), so they are safe to call
unconditionally, including from a background job (`ctx.app.submit` / a queue handler) where there
is no HTTP request.

## signal vs broadcast

```zig
// Signal-only (no payload). Subscribers receive {"type":"signal","topic":"availability"}
// and should re-fetch over an authenticated GET. The recommended default for private /
// per-subject state, since the channel carries nothing sensitive.
ctx.realtime().signal("availability");

// Payload-carrying. Subscribers receive
// {"type":"message","topic":"orders","data":{"type":"order.shipped","id":"REC1"}} verbatim.
try ctx.realtime().broadcast("orders", .{ .type = "order.shipped", .id = id });
```

**Security guidance.** Because a custom topic's frame is delivered verbatim to every subscriber
(no per-record `viewRule`), keep private/per-subject state **signal-only**: `signal(topic)`
carries no data, so a subscriber learns only that *something* changed and must re-fetch the actual
state over an authenticated GET. Use the payload-carrying `broadcast(topic, payload)` only for
data that is safe for **every** subscriber of that topic, and use `.canSubscribe` (below) to
restrict who may join a private channel.

## Gate subscriptions

By **default, custom topics are public signal channels** — anyone, including an anonymous socket,
may subscribe (exactly the framework's own `__features` signal). **A custom topic can never reach
a collection's record channels** — subscribing to a topic name that *is* a collection always goes
through that collection's normal record-channel authorization (per-record `viewRule`) instead. To
gate a private custom channel, supply a predicate:

```zig
const App = zigbase.App(.{
    .realtime = .{
        // Return true to allow the subscription, false to deny it. `ctx` carries the
        // socket's resolved identity (ctx.user() / ctx.rctx); `topic` is the requested
        // custom channel name.
        .canSubscribe = struct {
            fn f(ctx: *zigbase.Ctx, topic: []const u8) bool {
                if (std.mem.startsWith(u8, topic, "admin:")) {
                    const u = ctx.user() orelse return false;
                    return u.is_superuser;
                }
                return true; // other custom topics stay public
            }
        }.f,
    },
});
```

## From the client

A client subscribes to a custom topic exactly like a collection topic, over the raw WebSocket
protocol:

```js
const ws = new WebSocket(`ws://${location.host}/api/realtime`);
ws.onopen = () => ws.send(JSON.stringify({ action: "subscribe", topic: "availability" }));
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.topic === "availability") refreshSlots(); };
```

`@zigbase/client` 0.3.0+ wraps this in a typed helper, `subscribeTopic`, for custom channels:

```js
const unsub = await client.realtime.subscribeTopic('orders', (msg) => {
  // msg is the enveloped frame: { topic, kind: "signal" | "message", data? }
  if (msg.kind === 'message') console.log(msg.data);
});
// later: unsub();
```

`subscribeTopic` requires client **0.3.0 or newer** — older `@zigbase/client` versions only expose
the record-subscription helpers.

Custom-channel `broadcast`/`signal` events are currently **per-instance** — they are not (yet)
fanned out across app instances when running on the Postgres backend. Record-change events remain
the cross-instance path (see [Multi-instance realtime](./framework#multi-instance-realtime-postgres));
if you need a custom event to reach every instance, model it as a record write instead.

## Reference

- [ctx.realtime()](./framework#ctxrealtime--broadcast-on-custom-channels)
- [canSubscribe](./framework#who-may-subscribe-realtime---cansubscribe--fn)
- [Multi-instance realtime](./framework#multi-instance-realtime-postgres)
- [Realtime protocol](./api#realtime-websocket)
