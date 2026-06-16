import type { Transport } from "./transport.js";
import type { AuthStore } from "./auth-store.js";

export class CollectionService {
  constructor(
    protected readonly transport: Transport,
    protected readonly authStore: AuthStore,
    readonly name: string,
  ) {}

  protected base(): string {
    return `/api/collections/${encodeURIComponent(this.name)}`;
  }
}
