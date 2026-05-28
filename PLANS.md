# enxi-router: Implementation Plan

## Goal

Lightweight unified AI inference proxy in Zig. One set of standard endpoints. Client sends a request with a model ID, the router finds which provider serves that model and forwards it. The provider is invisible to the client.

```
Client                          enxi-router                    Upstream
------                          -----------                    --------
POST /v1/chat/completions       
  { model: "deepseek-v4-flash" } ---> model registry lookup ---> api.deepseek.com/v1/chat/completions
                                      allocate key
                                      forward + stream back

POST /v1/messages
  { model: "glm-4.7" }         ---> model registry lookup ---> api.z.ai/api/anthropic/v1/messages
                                      allocate key
                                      forward + stream back

GET  /v1/models                ---> merged list from all enabled providers
```

No `/x/{provider}/...` paths. No provider-specific URLs. The client talks to enxi-router as if it were a single provider.

Implementation progress is tracked in `TODO.md`.

## Design Principles

1. **Model-routed**: Model ID in the request body determines the upstream provider. Client never specifies a provider.
2. **Unified endpoints**: Standard OpenAI/Anthropic/Gemini API paths. Looks like one provider from the outside.
3. **Modular**: Middleware chain for extensibility. Add features without touching the proxy core.
4. **Config-compatible**: Provider YAML format based on mino. Minimal changes.
5. **Zero-copy streaming**: Stream upstream responses directly. Don't buffer entire bodies.

## Reference Source

`../../mino` (TypeScript/Bun). Read for behavior, not for translation.

---

## Architecture

```
Client Request
     |
     v
+-- HTTP Server (httpz) ------------------------------------------+
|                                                                  |
|  [Middleware Chain]                                              |
|    ip_extract        <- CF-Connecting-IP, X-Forwarded-For        |
|    schema_detect     <- detect schema from endpoint path+headers |
|    block_check       <- IP/country blocklist                     |
|                                                                  |
|  [Route Dispatch]                                                |
|    /v1/chat/completions       (OpenAI schema)                    |
|    /v1/completions            (OpenAI schema)                    |
|    /v1/embeddings             (OpenAI schema)                    |
|    /v1/models                 (merged model list)                |
|    /v1/models/:id             (single model info)                |
|    /v1/messages               (Anthropic schema)                 |
|    /v1beta/...:generateContent (Gemini schema)                   |
|                                                                  |
|  [Proxy Handler]                                                 |
|    1. Extract model ID from request body (or URL for Gemini)     |
|    2. Look up provider in model registry                         |
|    3. Verify provider supports the detected schema               |
|    4. Resolve schema config (base URL, upstream_path)            |
|    5. Strip/override headers                                     |
|    6. Apply model remap if configured                            |
|    7. Check cooldown, register request (concurrency)             |
|    8. Retry loop:                                                |
|       a. Allocate API key from pool                              |
|       b. Set auth header for schema                              |
|       c. Build upstream URL                                      |
|       d. Forward request                                         |
|       e. On error: rotate key, retry                             |
|    9. Stream response to client                                  |
|   10. Track usage, cleanup                                       |
|                                                                  |
+------------------------------------------------------------------+
```

### The Key Insight

In mino, the URL tells you the provider: `/x/deepseek/v1/chat/completions`.
In enxi-router, the body tells you the provider: `{ "model": "deepseek-v4-flash" }` on `/v1/chat/completions`.

This means we need a **model registry** -- a map from model ID to provider, built at startup from all provider configs.

### Model Registry

```zig
pub const ModelEntry = struct {
    provider_id: []const u8,
    upstream_model_id: []const u8,  // after remap, if any
};

pub const ModelRegistry = struct {
    entries: std.StringHashMap(ModelEntry),  // client_model_id -> entry
    
    pub fn lookup(self: *ModelRegistry, model_id: []const u8) ?ModelEntry;
    pub fn allModels(self: *ModelRegistry) [][]const u8;
    pub fn modelsForSchema(self: *ModelRegistry, schema: SchemaType) [][]const u8;
    pub fn rebuild(self: *ModelRegistry, allocator: Allocator, providers: []Provider) !void;
};
```

Built at startup:
```
for each enabled provider:
    models = provider.override.models (hardcoded) OR fetched from provider API
    models = apply filter_models allowlist
    for each model_id in models:
        upstream_id = remap_models[model_id] ?? model_id
        registry[model_id] = { provider.id, upstream_id }
```

If two providers serve the same model ID, first registered wins. Provider order in config determines priority.

---

## Project Structure

```
src/
  main.zig                # entry: load config, init DB, build registry, start server
  server.zig              # HTTP server, route table, middleware chain wiring
  context.zig             # RequestContext: per-request state passed through middleware

  config/
    config.zig            # load server config + provider configs from YAML
    types.zig             # Config, Provider, SchemaConfig, etc.

  db/
    database.zig          # SQLite: key pool + usage stats
    schema.zig            # table definitions

  memory/
    memory.zig            # sessions, cooldowns, key concurrency tracking

  registry/
    model_registry.zig    # model_id -> provider mapping

  middleware/
    ip_extract.zig        # extract IP + country from headers
    schema_detect.zig     # detect schema from endpoint path + headers
    block_check.zig       # IP/country blocklist

  proxy/
    handler.zig           # main proxy pipeline (the core)
    key_pool.zig          # key allocation, concurrency, retry
    upstream.zig          # build upstream URL + headers per schema

  schema/
    schema.zig            # Schema vtable + registry
    openai.zig            # OpenAI: auth, paths, SSE parse, token count
    anthropic.zig         # Anthropic: auth, paths, SSE parse, token count
    gemini.zig            # Gemini: auth, paths, SSE parse, token count

  stream/
    proxy_stream.zig      # stream upstream -> client (chunked)
    sse_reframe.zig       # fix malformed SSE event boundaries

  security/
    block_ip.zig          # file-backed IP blocklist
    block_country.zig     # file-backed country blocklist

  utils/
    logger.zig            # console logger
    time.zig              # parseDuration, msToHuman

data/
  config.yml              # server config
  providers/*.yml         # provider definitions (mino-compatible)
  db/database.db          # SQLite
  block_ip.txt
  block_country.txt

tests/
  test_config.zig
  test_registry.zig
  test_schema.zig
  test_proxy.zig
```

---

## Phase 0: Foundation

**What**: Build system, core types, skeleton.

### Tasks
1. `build.zig` + `build.zig.zon` with dependencies:
   - `httpz` (karlseguin) - HTTP server with middleware support
   - SQLite: direct C `sqlite3` or `sqlite.zig` wrapper
   - YAML: `knownyaml` or `yaml.zig` or C `libyaml`
2. `src/config/types.zig` - all shared types.

### Types

```zig
pub const SchemaType = enum { openai, anthropic, gemini };
pub const EndpointType = enum { chat_completion, image_generation, passthrough };
pub const KeyState = enum { active, ratelimited, error, disabled };

pub const Provider = struct {
    id: []const u8,
    keys_id: []const u8,
    enable: bool,
    hidden: bool,
    require_auth: bool,
    endpoint: EndpointConfig,
    schemas: []SchemaConfig,
    limit: PayloadLimit,
    concurrency: ConcurrencyConfig,
    override: OverrideConfig,
    filter_models: [][]const u8,
    remap_models: ?[]ModelRemap,
    cooldown: CooldownConfig,
    stream: ?StreamConfig,
    priority: u32 = 0,  // for model conflicts between providers
};

pub const SchemaConfig = struct {
    id: SchemaType,
    base: ?[]const u8,        // override base URL for this schema
    upstream_path: []const u8, // path prefix on upstream (e.g., /v1, /anthropic)
    strip_path: ?[]const u8,   // strip this from client path before appending
};

pub const EndpointConfig = struct {
    default: []const u8,
    named: std.StringHashMap([]const u8),
};

pub const PayloadLimit = struct {
    input: u32,
    output: u32,
};

pub const ConcurrencyConfig = struct {
    identity: u32,
    keys: KeyConcurrencyConfig,
};

pub const KeyConcurrencyConfig = struct {
    same_key: u32,
    max_usage_same_key: u32,
    key_stay_active: bool = false,
};

pub const OverrideConfig = struct {
    headers: []HeaderOverride,
    path: []PathOverride,
    models: [][]const u8,       // hardcoded model list (skip API fetch)
    strip_mode: StripMode = .default,
};

pub const ModelRemap = struct {
    client: []const u8,      // model ID the client sends
    upstream: []const u8,    // model ID sent to upstream
};

pub const CooldownConfig = struct {
    default: []const u8,
    chat_completion: ?[]const u8 = null,
};

pub const StreamConfig = struct {
    sse_reframe: bool = false,
    sse_keepalive: ?[]const u8 = null,
};

pub const ServerConfig = struct {
    port: u16,
    max_retry_count: u32 = 10,
};
```

### Config Format Change

Provider YAML gets a small addition for the unified router. The `override.models` field becomes the primary way to declare which models a provider serves:

```yaml
provider:
  id: deepseek
  keys_id: deepseek
  enable: true
  hidden: false
  require_auth: false
  priority: 10                    # NEW: higher = preferred on model conflicts
  endpoint:
    default: https://api.deepseek.com
  schema:
    - id: openai
      upstream_path: /v1
    - id: anthropic
      upstream_path: /anthropic
  override:
    models: ["deepseek-v4-flash", "deepseek-v4-pro"]
    # ... rest same as mino
```

Models can also be fetched from the provider API at startup (when `override.models` is empty). This matches mino's existing behavior.

### Deliverables
- `zig build` compiles a hello-world.
- All types defined and instantiable.

---

## Phase 1: Config Loading

**What**: Parse server config and provider YAML files.

### Tasks
1. `src/config/config.zig`:
   - `loadServerConfig(allocator, path) -> ServerConfig`
   - `loadProviders(allocator, dir_path) -> []Provider`
2. Validate required fields, apply defaults.

### Reference Files
- `data/config.yml` - only `server` section needed
- `data/providers/openai.yml` - simple single-schema provider
- `data/providers/deepseek.yml` - multi-schema, header overrides, hardcoded models
- `data/providers/zai.yml` - multi-schema with per-schema base URLs, strip_path

### Deliverables
- Parses real mino YAML files.
- Unit test: load each sample provider, verify all fields populated correctly.

---

## Phase 2: Database (Minimal)

**What**: SQLite for API key pool and usage tracking.

### Tasks
1. Two tables:

```sql
CREATE TABLE IF NOT EXISTS providers (
    id TEXT PRIMARY KEY,
    total_request INTEGER NOT NULL DEFAULT 0,
    total_tokens_input INTEGER NOT NULL DEFAULT 0,
    total_tokens_output INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS provider_keys (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_key_id TEXT NOT NULL,
    key TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL DEFAULT 'active',
    metadata TEXT DEFAULT '{}',
    total_used INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (unixepoch() * 1000),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch() * 1000)
);
```

2. Query surface:
   - `getRandomKey(keys_id, exclude_keys) -> ?KeyData`
   - `setKeyState(key, state)`
   - `incrProviderTokens(id, input, output)`
   - `incrProviderRequest(id)`
   - `initProviders(provider_ids)` - upsert provider rows on startup.

### Reference Files
- `data/db/schema.ts` - full schema (we only need `providers` + `provider_keys`)
- `server/core/database.ts` - query methods (we only need 5 of ~15)

### Deliverables
- DB opens with WAL mode, all 5 queries work.
- Unit test with `:memory:` database.

---

## Phase 3: Model Registry

**What**: The routing brain. Maps model IDs to providers.

### Tasks
1. `src/registry/model_registry.zig`:

```zig
pub const ModelRegistry = struct {
    // model_id (client-facing) -> { provider_id, upstream_model_id }
    entries: std.StringHashMap(ModelEntry),
    // provider_id -> [model_ids] (for model list endpoint)
    provider_models: std.StringHashMap([][]const u8),
    // provider_id -> Provider ref
    providers: std.StringHashMap(*const Provider),

    pub fn build(allocator: Allocator, providers: []const Provider) !ModelRegistry;
    pub fn lookup(self: *const ModelRegistry, model_id: []const u8) ?ModelEntry;
    pub fn allModels(self: *const ModelRegistry) [][]const u8;
    pub fn modelsForSchema(self: *const ModelRegistry, schema: SchemaType) [][]const u8;
    pub fn getProvider(self: *const ModelRegistry, provider_id: []const u8) ?*const Provider;
    pub fn getSchemaConfig(self: *const ModelRegistry, provider_id: []const u8, schema: SchemaType) ?SchemaConfig;
};

pub const ModelEntry = struct {
    provider_id: []const u8,
    upstream_model_id: []const u8,
};
```

2. Build algorithm:
```
for each provider (sorted by priority descending):
    models = provider.override.models
             OR fetchFromAPI(provider)  -- deferred, use override.models first
    models = filter(models, provider.filter_models)
    for each model_id:
        upstream_id = provider.remap_models[model_id] ?? model_id
        if model_id not already in registry:   // higher priority wins
            registry[model_id] = { provider.id, upstream_id }
        append to provider_models[provider.id]
```

3. Schema-aware model listing:
   - `modelsForSchema(.openai)` returns only models from providers that have an OpenAI schema config.
   - Used by `/v1/models` endpoint (filtered by detected schema).

### Reference
- `server/core/memory.ts` - `loadProviderModels()`, `setProviderModels()`
- `server/core/services.ts` - `fetchProviderModels()`

### Deliverables
- Registry builds from provider configs.
- `lookup("deepseek-v4-flash")` returns `{ provider: "deepseek", upstream: "deepseek-v4-flash" }`.
- `lookup("nonexistent")` returns null.
- Model conflict resolution: higher priority provider wins.
- `modelsForSchema(.openai)` returns correct subset.

---

## Phase 4: Memory & Key Pool

**What**: In-memory concurrency tracking and key allocation.

### Tasks
1. `src/memory/memory.zig`:

```zig
pub const Memory = struct {
    sessions: std.StringHashMap(Session),
    key_concurrency: std.StringHashMap(u32),

    pub fn tryRegisterRequest(self: *Memory, identity: []const u8, limit: u32) bool;
    pub fn unregisterRequest(self: *Memory, identity: []const u8) void;
    pub fn getCooldown(self: *Memory, identity: []const u8, kind: []const u8) i64;
    pub fn setCooldown(self: *Memory, identity: []const u8, kind: []const u8, expires_at: i64) void;
};
```

2. `src/proxy/key_pool.zig`:

```zig
pub fn allocateKey(
    memory: *Memory,
    db: *Database,
    identity: []const u8,
    provider: *const Provider,
) !KeyData {
    // 1. Check existing allocated key (max_usage_same_key reuse)
    // 2. Find saturated keys (concurrency >= same_key limit)
    // 3. Get random non-saturated key from DB
    // 4. Track allocation, increment concurrency
}

pub fn releaseKey(memory: *Memory, identity: []const u8, key: []const u8) void;
pub fn invalidateKey(memory: *Memory, identity: []const u8, keys_id: []const u8) void;
```

### Reference Files
- `server/core/memory.ts` - `allocateKey()`, `tryRegisterRequest()`, cooldowns
- Only allocation + concurrency + cooldown. No CIDR, no security state.

### Deliverables
- Key allocation with concurrency limits.
- Cooldown check/set.
- Identity concurrency enforcement.

---

## Phase 5: Schema Layer

**What**: Per-schema request/response handling via vtable.

### Tasks
1. `src/schema/schema.zig`:

```zig
pub const Schema = struct {
    type: SchemaType,

    // Auth
    setProviderKey: *const fn (headers: *Headers, key: []const u8) void,

    // Endpoint detection
    isChatEndpoint: *const fn (path: []const u8) bool,
    isModelListEndpoint: *const fn (path: []const u8) bool,

    // Request parsing
    getModelId: *const fn (body: []const u8) ?[]const u8,
    getMaxTokens: *const fn (body: []const u8) ?u32,
    getRequestToken: *const fn (body: []const u8) ?u32,

    // Request mutation
    rewriteModel: *const fn (alloc: Allocator, body: []const u8, new_model: []const u8) []const u8,

    // Response parsing
    parseSSEResponse: *const fn (alloc: Allocator, content: []const u8) ParsedResponse,

    // Model list formatting
    formatModelList: *const fn (alloc: Allocator, models: []const []const u8) []const u8,
    formatModelInfo: *const fn (alloc: Allocator, model_id: []const u8) []const u8,

    // Query params
    distillQuery: *const fn (params: *std.Uri.QueryParams) void,
};
```

2. Implement `openai.zig`, `anthropic.zig`, `gemini.zig`.

### Per-Schema Behavior

| Behavior | OpenAI | Anthropic | Gemini |
|----------|--------|-----------|--------|
| Auth header | `Authorization: Bearer {key}` | `x-api-key: {key}` | `x-goog-api-key: {key}` |
| Chat path match | `/chat/completions` | `/messages`, `/v1/messages` | `:generateContent`, `:streamGenerateContent` |
| Model list path | `/models` | `/models` | `/models` |
| Model from body | `json.model` | `json.model` | URL path `/models/{name}:` |
| Max tokens | `max_completion_tokens` or `max_tokens` | `max_tokens` | `generationConfig.maxOutputTokens` |
| SSE format | `data: {...}` + `[DONE]` | `data:` with `content_block_delta` | `data:` with `candidates` |
| Model list JSON | `{ data: [{id, object, ...}] }` | `{ data: [{id, ...}] }` | `{ models: [{name, ...}] }` |
| Query strip | none | none | strip `key` param |

### Reference Files
- `server/schema/base.ts`, `server/schema/openai.ts`, `server/schema/anthropic.ts`, `server/schema/gemini.ts`

### Deliverables
- Each schema implements all vtable functions.
- Unit tests: token counting, model extraction, SSE parsing per schema.

---

## Phase 6: Proxy Core

**What**: The main request pipeline. This is the heart of the router.

### Tasks
1. `src/proxy/handler.zig`:

```
Request arrives on /v1/chat/completions (or any standard endpoint)
  |
  v
1. Detect schema from endpoint path (done by middleware)
2. Read request body
3. Extract model ID from body (or URL for Gemini)
4. Registry lookup: model_id -> { provider_id, upstream_model_id }
5. Get provider config from registry
6. Get schema config for this provider + detected schema
   -> if provider doesn't support this schema: 400 error
7. Strip headers (full or minimal per provider config)
8. Apply header overrides
9. If model list endpoint -> return registry.allModels() in schema format
10. Validate model is in provider's model list
11. Check token limits (input/output)
12. Rewrite model ID if remapped (upstream_model_id != client model_id)
13. Check cooldown
14. Register request (concurrency limit)
15. Retry loop:
    a. Allocate key from pool
    b. Set auth header via schema
    c. Build upstream URL:
       base = schema_config.base ?? provider.endpoint.default
       path = schema_config.upstream_path + (client_path - strip_path)
       url = base + path
    d. Forward request
    e. On 401/403: invalidate key, retry
    f. On 402/429: mark key ratelimited, retry
    g. On 5xx: retry
    h. On success: stream response to client
16. Track output tokens from response
17. Update DB stats (tokens + request count)
18. Set cooldown, unregister request
```

2. `src/proxy/upstream.zig`: build upstream URL.

The critical difference from mino: we don't construct the URL from the path. We construct it from the schema config:

```zig
pub fn buildUpstreamUrl(
    alloc: Allocator,
    provider: *const Provider,
    schema_config: *const SchemaConfig,
    client_path: []const u8,
    query: []const u8,
) ![]const u8 {
    const base = schema_config.base orelse provider.endpoint.default;
    const upstream_path = schema_config.upstream_path;

    // Strip client path prefix if configured
    var endpoint = client_path;
    if (schema_config.strip_path) |strip| {
        if (std.mem.startsWith(u8, client_path, strip)) {
            endpoint = client_path[strip.len..];
        }
    }

    // Combine: base + upstream_path + endpoint
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ base, upstream_path, endpoint });
}
```

Example:
- Client sends: `POST /v1/chat/completions` with `model: "deepseek-v4-flash"`
- Registry says: provider=deepseek, schema_config={ id: openai, upstream_path: "/v1" }
- Provider endpoint: `https://api.deepseek.com`
- Result: `https://api.deepseek.com/v1/chat/completions`

Another example:
- Client sends: `POST /v1/messages` with `model: "deepseek-v4-flash"`
- Registry says: provider=deepseek, schema_config={ id: anthropic, upstream_path: "/anthropic" }
- Provider endpoint: `https://api.deepseek.com`
- Result: `https://api.deepseek.com/anthropic/v1/messages`

For zai with strip_path:
- Client sends: `POST /v1/chat/completions` with `model: "glm-4.7"`
- Registry says: provider=zai, schema_config={ id: openai, upstream_path: "/v4", strip_path: "/v1" }
- Provider endpoint: `https://api.z.ai/api/paas`
- Strip `/v1` from `/v1/chat/completions` -> `/chat/completions`
- Result: `https://api.z.ai/api/paas/v4/chat/completions`

3. `src/stream/proxy_stream.zig`: stream response chunks to client.

### Reference Files
- `server/server.ts` lines ~300-900 - the proxy pipeline
- `server/utils/stream.ts` - proxyResponseStream
- `server/utils/route.ts` - provider matching (we don't need this; we route by model)

### Deliverables
- `POST /v1/chat/completions` with any configured model routes to correct provider.
- Same model works on different schemas (if provider supports them).
- Key rotation on 401/429/5xx.
- SSE streams pass through correctly.
- Non-SSE responses pass through correctly.

---

## Phase 7: Stream Handling

**What**: SSE reframing and keepalive.

### Tasks
1. `src/stream/sse_reframe.zig`: fix concatenated SSE frames.
   - Buffer partial lines.
   - Split at `}data: {` boundaries.
   - Emit complete events with proper `\n\n` separators.
   - Reference: `server/utils/sse-reframe.ts`

2. SSE keepalive (per-provider config):
   - Inject `: keepalive\n\n` at configurable interval during idle.
   - Reference: `server/utils/sse-keepalive.ts`

### Deliverables
- Malformed SSE from upstream arrives clean to client.
- Keepalive prevents proxy timeout on slow generations.

---

## Phase 8: Security + Middleware

**What**: IP/country blocking, IP extraction, schema detection, middleware chain.

### Tasks

1. `src/security/block_ip.zig`: file-backed IP blocklist.
2. `src/security/block_country.zig`: file-backed country blocklist.
3. `src/middleware/ip_extract.zig`:
   - `CF-Connecting-IP` or `X-Forwarded-For` or `X-Real-IP`.
   - `CF-IPCountry` (default "AQ").
   - Basic IPv4-mapped IPv6 normalization.
4. `src/middleware/schema_detect.zig`:
   - Path-based: `/chat/completions`, `/completions`, `/embeddings` -> openai
   - Path-based: `/messages` -> anthropic
   - Path-based: `:generateContent`, `:streamGenerateContent` -> gemini
   - Header-based: `x-api-key` or `anthropic-version` -> anthropic
   - Header-based: `x-goog-api-key` -> gemini
   - Fallback: `Authorization: Bearer` -> openai
5. `src/middleware/block_check.zig`: check IP + country against blocklists.
6. Wire chain in `src/server.zig`:

```zig
const chain = &[_]Middleware{
    ip_extract,
    schema_detect,
    block_check,
};
// chain executes in order, last calls into dispatch
```

### Reference Files
- `server/plugins/cloudflare.ts` - IP extraction
- `server/plugins/identity.ts` - schema detection (adapted for unified endpoints)
- `server/security/block-ip.ts`, `server/security/block-country.ts`

### Deliverables
- Schema auto-detected correctly for all three formats.
- Blocked IPs/countries get 403.
- Adding a new middleware is one file + one line in the chain.

---

## Phase 9: Model List Endpoint

**What**: `GET /v1/models` returns a unified model list.

### Tasks
1. When client hits `/v1/models`:
   - Detect schema from headers (same logic as chat endpoints).
   - Get all models from registry that are available for the detected schema.
   - Format using the schema's `formatModelList` function.
   - Return response.

2. When client hits `/v1/models/{model_id}`:
   - Look up in registry.
   - If not found: 404.
   - Format using schema's `formatModelInfo`.

3. Hidden providers excluded from model list.
4. Disabled providers excluded.

### Reference
- mino returns model list per-provider. We merge them.
- Format matches what clients expect (OpenAI, Anthropic, or Gemini format).

### Deliverables
- `GET /v1/models` with OpenAI auth returns OpenAI-format list of all models.
- `GET /v1/models` with Anthropic headers returns Anthropic-format list.
- Individual model lookup works.

---

## Phase 10: Integration & Polish

**What**: Wire everything in `main.zig`. Make it runnable.

### Tasks
1. `src/main.zig`:
   - Load config.
   - Open DB, run migrations.
   - Build model registry from provider configs.
   - Initialize memory.
   - Build middleware chain.
   - Start HTTP server.
   - Graceful shutdown on SIGTERM/SIGINT.

2. Error handling audit:
   - Every error union has a handler.
   - Model not found -> 400 with schema-appropriate error format.
   - Provider doesn't support schema -> 400.
   - All keys saturated -> 503.
   - Upstream timeout -> proper error in client's schema format.

3. Startup logging:
   - Print loaded providers and model count.
   - Print registry size.
   - Print listen address.

### Deliverables
- `zig build run` starts the server.
- `curl http://localhost:PORT/v1/chat/completions` with `{"model":"deepseek-v4-flash",...}` proxies to deepseek.
- `curl http://localhost:PORT/v1/models` returns merged model list.
- SSE streaming works end-to-end.
- Key rotation works on 429.

---

## Extensibility

New features are middleware or new modules. The proxy core should rarely change.

| Future Feature | How to Add |
|---|---|
| Rate limiting | New middleware `middleware/rate_limit.zig` |
| Request/response logging | New middleware `middleware/logging.zig` |
| Payload fingerprinting | New middleware `middleware/fingerprint.zig` |
| User auth & permissions | Extend `middleware/schema_detect.zig` + add `db/users.zig` |
| Request rewriting | New middleware `middleware/rewrite.zig` |
| Response caching | New middleware `middleware/cache.zig` |
| Schema translation (OpenAI <-> Anthropic) | New module `translate/` hooked between proxy steps 6 and 7 |
| Admin API | New route in `server.zig` |
| Health check | New route in `server.zig` |
| New schema (Cohere, Mistral) | New file `schema/cohere.zig` + register |
| Dynamic model fetching | Extend `registry/model_registry.zig` with API fetch |
| WebSocket dashboard | Independent module, separate from proxy |

### Adding a New Provider

1. Add `data/providers/new_provider.yml` (same format as mino).
2. Add API keys to `provider_keys` table in SQLite.
3. Restart (or reload). Registry rebuilds automatically.
4. Done. The new provider's models are routable immediately.

No code changes needed for new providers. It's purely config.

### Adding a New Schema

1. Create `src/schema/new_schema.zig` implementing the vtable.
2. Register in `src/schema/schema.zig`.
3. Add path detection rules in `middleware/schema_detect.zig`.
4. Done.

---

## What's Excluded

- Web UI, WebSocket, image gallery, cursor tracking, admin dashboard
- User auth system (deferred)
- Advanced security modules (available as future middleware)
- Schema translation between formats (complex; each schema endpoint speaks its own language)
- Image generation handling (can be added later as an endpoint type)

---

## Dependency Decisions

### HTTP Server: `httpz`
- Mature, supports streaming, middleware, routing.
- Thread pool model.

### SQLite: C `sqlite3` or `sqlite.zig`
- 5 queries. Direct C bindings are simplest.
- WAL mode.

### YAML: `knownyaml` or `yaml.zig`
- Provider configs use nested maps, arrays of objects, optional fields.
- Pick whichever handles this cleanly.

### JSON: `std.json`
- Built-in. Use `Scanner` for streaming parse of large bodies.

---

## Testing

**Unit tests** (in-file):
- Config: parse real YAML provider files.
- Registry: build from providers, lookup models, conflict resolution.
- Schema: token count, model extraction, SSE parse per schema.
- Key pool: allocation, concurrency limits, cooldown.
- Upstream URL: build URLs for various provider+schema combos.

**Integration tests**:
- Mock upstream. Send request, verify routing by model ID.
- Test retry: mock returns 429, verify key rotation.
- Test model list: verify merged output.
- Test schema detection: verify correct schema for each endpoint.

**Manual tests**:
- `curl` with real provider keys.
- Compare responses against direct provider calls.
