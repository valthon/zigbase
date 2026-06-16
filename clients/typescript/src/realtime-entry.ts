import type { Client } from "./client.js";
import { INTERNALS, type WithInternals } from "./internal.js";
import { RealtimeService, type RealtimeEvent } from "./realtime.js";
import { LiveCollection, type LiveReader, type LiveSubscriber } from "./live/live-collection.js";

// Re-export the realtime / live-store / filter-eval public surface from this entry,
// so everything that pulls in that graph is reachable only via `@zigbase/client/realtime`.
export { RealtimeService } from "./realtime.js";
export type { RealtimeEvent, RealtimeCallback, RealtimeAction } from "./realtime.js";
export { LiveCollection, LiveList } from "./live/live-collection.js";
export type {
  LiveReader,
  LiveSubscriber,
  LiveListOpts,
  LiveListMode,
  CloseableLiveRecord,
} from "./live/live-collection.js";
export { LiveRecord, RecordCache } from "./live/cache.js";
export type { Observable } from "./live/cache.js";
export { parseFilter, evaluateFilter, analyzeFilter } from "./live/filter-eval.js";
export type { FilterNode, FilterAnalysis } from "./live/filter-eval.js";

export interface RealtimeClient extends LiveSubscriber {
  subscribe(
    topic: string,
    cb: (e: RealtimeEvent) => void,
    opts?: { filter?: string },
  ): Promise<() => void>;
  unsubscribe(topic: string, cb?: (e: RealtimeEvent) => void): void;
  collection(name: string): LiveCollection;
}

/** A base client with realtime bolted on. */
export type RealtimeEnabledClient = Client & { readonly realtime: RealtimeClient };

/**
 * Attach the realtime + live-store API to a base client and return it (typed).
 * ALL realtime/live/filter-eval code lives in this entry's import graph only, so a
 * REST-only app that never imports `@zigbase/client/realtime` shakes it all out.
 *
 *   import { createClient } from "@zigbase/client";
 *   import { withRealtime } from "@zigbase/client/realtime";
 *   const zb = withRealtime(createClient(url, { WebSocket }));
 *   await zb.realtime.subscribe("posts", (e) => { ... });
 */
export function withRealtime<C extends Client>(client: C): C & { readonly realtime: RealtimeClient } {
  const internals = (client as unknown as WithInternals)[INTERNALS];
  if (!internals) {
    throw new Error("withRealtime: client was not created by createClient()");
  }

  let service: RealtimeService | null = null;
  const getService = (): RealtimeService => {
    if (!service) {
      if (!internals.WebSocket) {
        throw new Error("No WebSocket implementation available; pass options.WebSocket");
      }
      service = new RealtimeService({
        baseUrl: internals.baseUrl,
        authStore: internals.authStore,
        WebSocket: internals.WebSocket,
      });
    }
    return service;
  };

  const realtime: RealtimeClient = {
    subscribe: (topic, cb, subOpts) => getService().subscribe(topic, cb, subOpts),
    unsubscribe: (topic, cb) => getService().unsubscribe(topic, cb),
    collection: (name) =>
      new LiveCollection(name, internals.makeReader(name) as unknown as LiveReader, getService()),
  };

  Object.defineProperty(client, "realtime", {
    value: realtime,
    enumerable: true,
    configurable: true,
    writable: false,
  });

  return client as C & { readonly realtime: RealtimeClient };
}
