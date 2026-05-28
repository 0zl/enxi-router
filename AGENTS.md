# enxi-router: Agent Guidelines

## What This Is

A unified AI inference proxy in Zig. One set of standard endpoints (`/v1/chat/completions`, `/v1/messages`, etc.). The client sends a request with a model ID, and the router finds which provider serves that model and forwards it. The provider is invisible to the client.

```
Client:  POST /v1/chat/completions { "model": "deepseek-v4-flash", ... }
Router:  model registry lookup -> deepseek provider -> https://api.deepseek.com/v1/chat/completions
Client:  gets the response back as if talking to one unified provider
```

Reference implementation: `../../mino` (TypeScript/Bun). We take only the proxy core, restructured around model-based routing instead of provider-path routing.

## Architecture

```
Request -> [Middleware Chain] -> [Model Registry Lookup] -> [Proxy Handler] -> Upstream
                  |                       |                       |
           ip_extract              model_id -> provider      key pool (SQLite)
           schema_detect                                   retry + stream
           block_check
```

### Core Modules

| Module | Purpose |
|--------|---------|
| `config/` | YAML config + provider loading |
| `db/` | SQLite: key pool + usage stats (2 tables) |
| `memory/` | Sessions, cooldowns, key concurrency |
| `registry/` | Model ID -> provider mapping (the routing brain) |
| `middleware/` | Request processing chain (extensibility point) |
| `proxy/` | Forward requests, manage keys, retry, stream |
| `schema/` | Per-schema auth, parsing, formatting (vtable) |
| `stream/` | SSE proxy, reframing |
| `security/` | IP/country blocking |
| `utils/` | Logger, time parsing |

### Key Difference from mino

mino routes by URL path: `/x/{provider}/v1/chat/completions`
enxi-router routes by model ID: `/v1/chat/completions` with `{ "model": "..." }`

The model registry is what makes this work. It's built at startup from all provider configs.

## Conventions

### Code Style
- Standard Zig: `snake_case` functions, `PascalCase` types, `UPPER_SNAKE` constants.
- Every allocating function takes `std.mem.Allocator`. No hidden allocations.
- Arena allocators for request-scoped work. Defer cleanup at scope top.
- Error unions (`!T`) everywhere.
- `[]const u8` for strings.

### Naming
- Match mino's domain terms: provider, schema, identity, cooldown, keys_id.
- The model registry is new. Use: `model_id`, `upstream_model_id`, `provider_id`.

### Memory
- Request: arena per-request, freed on response sent.
- Long-lived (sessions, providers, registry): server-level allocator.
- Stream buffers: fixed-size, reusable.

### Config
- Provider YAML: mino-compatible format with a `priority` field for conflict resolution.
- `override.models` is the primary way to declare a provider's model list.
- Models can also be fetched from provider API at startup (future).

## How to Use the Reference

When implementing a module:
1. Read the mino source listed in PLANS.md for that module.
2. Understand inputs, outputs, state changes.
3. Write Zig equivalent with explicit memory management.
4. Verify edge cases (unknown model, schema mismatch, upstream 401).

Don't blindly translate. Key differences:
- mino matches provider from URL. We match from model ID in body.
- mino's identity plugin detects schema from headers. We detect from endpoint path first.
- mino returns per-provider model lists. We return a merged list.

## Extending

### New middleware
```zig
// src/middleware/new_feature.zig
pub fn handle(alloc: Allocator, ctx: *RequestContext, next: NextFn) !Response {
    // pre-processing
    const resp = try next(alloc, ctx);
    // post-processing
    return resp;
}
```
Add to chain in `server.zig`. Done.

### New provider
1. Add `data/providers/new_provider.yml`.
2. Add API keys to SQLite.
3. Restart. Registry rebuilds. No code changes.

### New schema (e.g., Cohere)
1. Create `src/schema/cohere.zig` with vtable implementation.
2. Register in `src/schema/schema.zig`.
3. Add path rules in `middleware/schema_detect.zig`.

### New route (e.g., health check)
Add handler in `server.zig` route table.

## What's Not Included

Web UI, WebSocket, image gallery, admin dashboard, user auth (deferred), advanced security (future middleware), schema translation between formats.

See PLANS.md for full details. See TODO.md for implementation tracking.
