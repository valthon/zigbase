# Why ZigBase

Build beyond your team size. ZigBase is an open-source backend and embeddable Zig
framework for ambitious applications built by individuals and small teams. It brings
application services together while leaving you in control of business logic,
resource use, and deployment.

A solo developer with a frontier coding agent is a central audience. So is a developer
who wants to write every line. The framework, documentation, compiler feedback, and
local test tools are the same in both workflows. No AI service or subscription is
required to build or run a ZigBase application.

## Application leverage, systems control

Auth, collections, access rules, files, realtime, jobs, and an admin UI give you a
working foundation. Extend that foundation inside your application with typed Zig
hooks, routes, schema, migrations, and storage or mailer plugins. You can keep a custom
business operation in the same process and transaction as the records it changes.

Run the stock server when its API expresses your product. Embed the framework when
you need server-owned decisions, custom integrations, or background work. Both use the
same collection API and client model. See [app design](app-genesis.md), the
[framework reference](framework.md), and the [worked tutorial](tutorial.md).

## Why Zig is central

[Zig](https://ziglang.org/) makes allocation and control flow explicit and supports
compile-time execution. ZigBase uses those properties to make application structure
and resource choices visible:

- **Compile-time composition.** `App(cfg)` assembles schema, hooks, routes, and jobs.
  Invalid configuration keys and handler shapes fail during compilation. Optional
  subsystems can be excluded from a custom build.
- **Explicit allocation and lifetime.** Request arenas and allocator-aware APIs expose
  where values live. Application code is responsible for respecting those lifetimes;
  copy values into the owning arena when they must outlive a hook invocation.
- **Resource choices you can inspect.** Resource profiles, explicit pool overrides,
  and the `resources` report expose selected connection, worker, stack, and SQLite
  cache settings. These are tunable components, not a total process-memory ceiling.
- **Measurements you can act on.** `zigbase tune` compares supplied measurements
  against memory and p95 latency budgets. Performance contracts can gate binary size
  and instrumented allocations in CI; timing comparisons remain advisory.

These tools support deliberate performance engineering. No garbage collector does
not mean no contention, no allocation cost, or constant latency. Database work,
external services, the OS, and your application code still determine performance.
Logical allocation measurements are not process RSS. Use the
[resource and tuning reference](framework.md#10-footprint-levers-pools) and
[performance contracts](testing.md#performance-contracts) to understand the boundaries.

## Write it yourself. Build it with an agent. Mix both.

For direct development, the public Zig API, runnable examples, typed clients, and
in-process tests provide a normal code-first workflow. Start with the
[tutorial](tutorial.md), then use the [recipes](recipes.md) and
[framework reference](framework.md) as the application grows.

For agent-assisted development, scaffolding adds project instructions; CLI discovery,
structured output, stable error codes, and schema inspection give an agent feedback it
can act on. The same test and build commands remain available to you. Start with the
[agent orientation](agents.md) and review the [agent evaluation evidence](agent-evals.md).

Explicitness is useful to both readers. A compiler diagnostic that names a misspelled
configuration key saves a developer a debugging session and gives an agent a concrete
correction. Agent support is an additional way to work with the framework, not a
separate runtime or a requirement to send your source to an external service.

## Start with a modest machine; measure the next step

The default backend uses embedded SQLite and ships as a single binary. Serve frontend
assets from that same process to keep the initial deployment small. Pair with
[Zigapagos](zigapagos-pairing.md) for pages, layouts, and interactive islands, or use
another frontend through the HTTP API and clients.

Use one SQLite writer process. When the workload calls for multiple application
instances, the opt-in [PostgreSQL backend](postgres.md) and `migrate-db` provide a
path forward. Rehearse the data move, audit backend-specific SQL, and review shared
files, scheduling, and realtime requirements before adding replicas. Moving databases
is an operational change even when collection API calls stay the same.

The ambition is substantial applications on efficient infrastructure. Capacity is a
property of a measured workload and deployment, not a universal user-count claim.
See [deployment](deployment.md) for the operating model and the
[engineering backlog](../BACKLOG.md) for the work toward that ambition.

## Evidence and boundaries

The repository includes runnable applications, CI checks across backend and feature
configurations, allocation/size contracts, and recorded agent evaluations. The Genesis
checkpoint records three successful unattended runs at a specific historical revision;
it is evidence for that scenario, not qualification of every later revision or app.

ZigBase is an early release. Consult [known limitations](../KNOWN_LIMITATIONS.md)
and the [security support policy](../SECURITY.md) when choosing a release. We distinguish
implemented capabilities, reproducible measurements, and future objectives. Broad
enterprise-scale and comparative cost claims need application-level evidence; the
backlog makes that evidence part of the work.
