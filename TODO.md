# enxi-router: TODO

## Status Legend

- `[ ]` not started
- `[~]` in progress
- `[x]` done

---

## Phase 0: Foundation

### Build System
- [ ] `build.zig` - project build configuration
- [ ] `build.zig.zon` - dependency manifest (httpz, sqlite, yaml)

### Dependencies
- [ ] Evaluate and choose HTTP server (`httpz` vs raw)
- [ ] Evaluate and choose YAML parser (`knownyaml` vs `yaml.zig` vs C `libyaml`)
- [ ] Evaluate and choose SQLite binding (direct C `sqlite3` vs `sqlite.zig`)
- [ ] Wire dependencies into `build.zig.zon`

### Core Types (`src/config/types.zig`)
- [ ] `SchemaType` enum (openai, anthropic, gemini)
- [ ] `EndpointType` enum (chat_completion, image_generation, passthrough)
- [ ] `KeyState` enum (active, ratelimited, error, disabled)
- [ ] `Provider` struct
- [ ] `SchemaConfig` struct
- [ ] `EndpointConfig` struct
- [ ] `PayloadLimit` struct
- [ ] `ConcurrencyConfig` + `KeyConcurrencyConfig` structs
- [ ] `OverrideConfig` struct (headers, path overrides, models, strip_mode)
- [ ] `ModelRemap` struct (client -> upstream model ID mapping)
- [ ] `CooldownConfig` struct
- [ ] `StreamConfig` struct
- [ ] `ServerConfig` struct

### Documentation
- [x] `AGENTS.md` - agent guidelines
- [x] `PLANS.md` - implementation plan
- [x] `TODO.md` - this file

---

## Phase 1: Config Loading

### Config Loader (`src/config/config.zig`)
- [ ] `loadServerConfig(allocator, path) -> ServerConfig`
- [ ] `loadProviders(allocator, dir_path) -> []Provider`
- [ ] Handle required vs optional fields with defaults
- [ ] Validate provider config (non-empty id, at least one schema, valid endpoint)

### Tests
- [ ] Parse `openai.yml` - single schema, simple provider
- [ ] Parse `deepseek.yml` - multi-schema, header overrides, hardcoded models
- [ ] Parse `zai.yml` - multi-schema with per-schema base URLs, strip_path
- [ ] Parse `gemini-flash.yml` - keys_metadata, filter_models, scripts
- [ ] Error on malformed YAML (missing required fields)

---

## Phase 2: Database

### Schema (`src/db/schema.zig`)
- [ ] `providers` table (id, total_request, total_tokens_input, total_tokens_output)
- [ ] `provider_keys` table (id, provider_key_id, key, state, metadata, total_used, timestamps)
- [ ] Migration logic (CREATE TABLE IF NOT EXISTS)

### Database (`src/db/database.zig`)
- [ ] Open SQLite with WAL mode + busy timeout
- [ ] `initProviders(provider_ids)` - upsert provider rows
- [ ] `getRandomKey(keys_id, exclude_keys) -> ?KeyData` - random active key
- [ ] `setKeyState(key, state)` - update key lifecycle
- [ ] `incrProviderTokens(id, input, output)` - usage tracking
- [ ] `incrProviderRequest(id)` - request counting

### Tests
- [ ] Open in-memory DB, run migrations
- [ ] Insert keys, verify random selection with exclusion
- [ ] Set key state, verify persistence
- [ ] Increment tokens, verify accumulation

---

## Phase 3: Model Registry

### Registry (`src/registry/model_registry.zig`)
- [ ] `ModelEntry` struct (provider_id, upstream_model_id)
- [ ] `build(allocator, providers) -> ModelRegistry` - construct from provider configs
- [ ] `lookup(model_id) -> ?ModelEntry` - find provider for a model
- [ ] `allModels() -> [][]const u8` - all registered models
- [ ] `modelsForSchema(schema) -> [][]const u8` - models filtered by schema support
- [ ] `getProvider(provider_id) -> ?*const Provider`
- [ ] `getSchemaConfig(provider_id, schema) -> ?SchemaConfig`
- [ ] Priority-based conflict resolution (higher priority provider wins)
- [ ] Apply `filter_models` allowlist during build
- [ ] Apply `remap_models` during build (store upstream_model_id)

### Tests
- [ ] Build from multiple providers, verify all models registered
- [ ] Lookup existing model -> correct provider
- [ ] Lookup nonexistent model -> null
- [ ] Two providers with same model -> higher priority wins
- [ ] `modelsForSchema(.openai)` excludes providers without openai schema
- [ ] Remapped model stores correct upstream_model_id
- [ ] Disabled/hidden providers excluded

---

## Phase 4: Memory & Key Pool

### Memory (`src/memory/memory.zig`)
- [ ] `Session` struct (active_requests count, cooldowns, allocated_keys)
- [ ] `tryRegisterRequest(identity, limit) -> bool` - concurrency enforcement
- [ ] `unregisterRequest(identity)` - decrement active count
- [ ] `getCooldown(identity, kind) -> i64` - check cooldown expiry
- [ ] `setCooldown(identity, kind, expires_at)` - set cooldown
- [ ] `getAllocatedKey(identity, keys_id) -> ?AllocatedKey` - reuse check
- [ ] `setAllocatedKey(identity, keys_id, key)` - track allocation
- [ ] `invalidateKey(identity, keys_id)` - clear allocated key
- [ ] Key concurrency tracking (per-key concurrent usage count)

### Key Pool (`src/proxy/key_pool.zig`)
- [ ] `allocateKey(memory, db, identity, provider) -> !KeyData`
  - [ ] Reuse existing key if under `max_usage_same_key`
  - [ ] Find saturated keys (concurrency >= `same_key` limit)
  - [ ] Request random non-saturated key from DB
  - [ ] Track allocation + increment concurrency
  - [ ] Error if all keys saturated
- [ ] `releaseKey(memory, identity, key)` - decrement concurrency
- [ ] `invalidateAndRetry(memory, identity, keys_id)` - invalidate current, allocate new

### Tests
- [ ] Register request under limit -> success
- [ ] Register request at limit -> rejected
- [ ] Allocate key -> returns active key
- [ ] Allocate when key saturated -> returns different key
- [ ] Allocate when all saturated -> error
- [ ] Cooldown not expired -> blocked
- [ ] Cooldown expired -> allowed
- [ ] Key reuse within max_usage_same_key -> same key returned

---

## Phase 5: Schema Layer

### Schema Interface (`src/schema/schema.zig`)
- [ ] `Schema` vtable struct (function pointers)
- [ ] `ParsedResponse` struct (content, token_count)
- [ ] Schema registry (SchemaType -> Schema instance)
- [ ] `getSchema(SchemaType) -> *const Schema`

### OpenAI (`src/schema/openai.zig`)
- [ ] `setProviderKey` - `Authorization: Bearer {key}`
- [ ] `isChatEndpoint` - matches `/chat/completions`
- [ ] `isModelListEndpoint` - matches `/models`
- [ ] `getModelId` - extract `json.model`
- [ ] `getMaxTokens` - `max_completion_tokens` or `max_tokens`
- [ ] `getRequestToken` - estimate tokens from message text
- [ ] `parseSSEResponse` - parse `data: {...}` lines, handle `data: [DONE]`
- [ ] `formatModelList` - `{ data: [{ id, object, created, owned_by }] }`
- [ ] `formatModelInfo` - single model object
- [ ] `rewriteModel` - replace `json.model` in body
- [ ] `distillQuery` - no-op for OpenAI

### Anthropic (`src/schema/anthropic.zig`)
- [ ] `setProviderKey` - `x-api-key: {key}`
- [ ] `isChatEndpoint` - matches `/messages`, `/v1/messages`
- [ ] `isModelListEndpoint` - matches `/models`
- [ ] `getModelId` - extract `json.model`
- [ ] `getMaxTokens` - `json.max_tokens`
- [ ] `getRequestToken` - estimate tokens from message text
- [ ] `parseSSEResponse` - parse `content_block_delta` events
- [ ] `formatModelList` - `{ data: [{ id, created_at, display_name, type }] }`
- [ ] `formatModelInfo` - single model object
- [ ] `rewriteModel` - replace model in body
- [ ] `distillQuery` - no-op for Anthropic

### Gemini (`src/schema/gemini.zig`)
- [ ] `setProviderKey` - `x-goog-api-key: {key}`
- [ ] `isChatEndpoint` - matches `:generateContent`, `:streamGenerateContent`, `:generateContentBatch`
- [ ] `isModelListEndpoint` - matches `/models`
- [ ] `getModelId` - extract from URL path `/models/{name}:`
- [ ] `getMaxTokens` - `generationConfig.maxOutputTokens`
- [ ] `getRequestToken` - estimate tokens from contents/parts
- [ ] `parseSSEResponse` - parse `candidates[].content.parts[].text`
- [ ] `formatModelList` - `{ models: [{ name, displayName, ... }] }`
- [ ] `formatModelInfo` - single model object
- [ ] `rewriteModel` - replace model in URL or body
- [ ] `distillQuery` - strip `key` query parameter

### Tests (per schema)
- [ ] OpenAI: extract model ID from sample body
- [ ] OpenAI: count tokens from sample messages
- [ ] OpenAI: parse SSE stream with multiple chunks
- [ ] OpenAI: parse non-streaming response
- [ ] Anthropic: extract model ID from sample body
- [ ] Anthropic: parse SSE content_block_delta events
- [ ] Anthropic: format model list in Anthropic format
- [ ] Gemini: extract model ID from URL path
- [ ] Gemini: parse SSE candidates response
- [ ] Gemini: distill query params (strip key)

---

## Phase 6: Proxy Core

### Proxy Handler (`src/proxy/handler.zig`)
- [ ] Read request body
- [ ] Extract model ID from body (or URL for Gemini)
- [ ] Registry lookup: model_id -> provider + upstream_model_id
- [ ] Get provider config + schema config
- [ ] Return 400 (schema-format error) if model not found
- [ ] Return 400 if provider doesn't support detected schema
- [ ] Strip headers (full or minimal per provider `strip_mode`)
- [ ] Apply header overrides from provider config
- [ ] Handle model list endpoint (delegate to Phase 9)
- [ ] Validate model against provider's model list
- [ ] Check token limits (input/output)
- [ ] Rewrite model ID if remapped
- [ ] Check cooldown
- [ ] Register request (concurrency limit)
- [ ] Retry loop:
  - [ ] Allocate key from pool
  - [ ] Set auth header via schema vtable
  - [ ] Build upstream URL
  - [ ] Forward request to upstream
  - [ ] Handle 401/403: invalidate key, retry
  - [ ] Handle 402/429: mark key ratelimited, retry
  - [ ] Handle 5xx: retry
  - [ ] Max retries exceeded: return 503
- [ ] Stream response to client on success
- [ ] Track output tokens from response
- [ ] Update DB stats (tokens + request count)
- [ ] Set cooldown, unregister request (cleanup)
- [ ] Handle upstream idle timeout
- [ ] Handle client disconnect (abort upstream)

### Upstream URL Builder (`src/proxy/upstream.zig`)
- [ ] `buildUpstreamUrl(provider, schema_config, client_path, query) -> []const u8`
- [ ] Use `schema_config.base` or fallback to `provider.endpoint.default`
- [ ] Prepend `schema_config.upstream_path`
- [ ] Apply `schema_config.strip_path` to client path
- [ ] Append distilled query parameters
- [ ] Normalize double slashes in URL

### Stream Proxy (`src/stream/proxy_stream.zig`)
- [ ] Read upstream response in chunks
- [ ] Forward each chunk to client immediately
- [ ] Accumulate body text for response callback
- [ ] Handle client disconnect -> cancel upstream
- [ ] Handle upstream error mid-stream
- [ ] Support SSE reframe (toggle per provider config)
- [ ] Support SSE keepalive (toggle per provider config)

### Tests
- [ ] Upstream URL: OpenAI provider, standard path
- [ ] Upstream URL: multi-schema provider (Anthropic schema on deepseek)
- [ ] Upstream URL: provider with strip_path (zai)
- [ ] Upstream URL: query parameter passthrough
- [ ] Proxy: model not found -> 400 error
- [ ] Proxy: schema not supported by provider -> 400
- [ ] Proxy: all keys saturated -> 503
- [ ] Proxy: upstream 401 -> key invalidated, retry with new key
- [ ] Proxy: upstream 429 -> key marked ratelimited, retry
- [ ] Proxy: max retries exceeded -> 503
- [ ] Proxy: SSE stream passes through correctly

---

## Phase 7: Stream Handling

### SSE Reframe (`src/stream/sse_reframe.zig`)
- [ ] Buffer partial lines across chunks
- [ ] Detect concatenated `}data: {` boundaries
- [ ] Split and emit with proper `\n\n` separators
- [ ] Handle flush (remaining buffer at stream end)

### SSE Keepalive (optional, per-provider)
- [ ] Inject `: keepalive\n\n` at configurable interval
- [ ] Reset timer on real data arrival
- [ ] Stop on stream end

### Tests
- [ ] Reframe: two events concatenated in one chunk -> two separate events
- [ ] Reframe: normal events pass through unchanged
- [ ] Reframe: partial line buffered until next chunk
- [ ] Keepalive: injects comment after idle period
- [ ] Keepalive: resets on data arrival

---

## Phase 8: Security + Middleware

### IP Extraction (`src/middleware/ip_extract.zig`)
- [ ] Read `CF-Connecting-IP` header
- [ ] Fallback to `X-Forwarded-For` (first entry)
- [ ] Fallback to `X-Real-IP`
- [ ] Final fallback to `127.0.0.1`
- [ ] Read `CF-IPCountry` (default to "AQ")
- [ ] IPv4-mapped IPv6 normalization (`::ffff:1.2.3.4` -> `1.2.3.4`)
- [ ] IPv6 privacy extension prefix extraction (first 4 groups)

### Schema Detection (`src/middleware/schema_detect.zig`)
- [ ] Path-based: `/chat/completions`, `/completions`, `/embeddings` -> openai
- [ ] Path-based: `/messages` -> anthropic
- [ ] Path-based: `:generateContent`, `:streamGenerateContent` -> gemini
- [ ] Header-based: `x-api-key` or `anthropic-version` -> anthropic
- [ ] Header-based: `x-goog-api-key` -> gemini
- [ ] Fallback: `Authorization: Bearer` -> openai
- [ ] Store detected schema in RequestContext

### Block Check (`src/middleware/block_check.zig`)
- [ ] Check IP against blocklist -> 403 if blocked
- [ ] Check country against blocklist -> 403 if blocked

### IP Blocklist (`src/security/block_ip.zig`)
- [ ] Load IPs from `data/block_ip.txt`
- [ ] `isBlocked(ip) -> bool`
- [ ] Hot-reload on file change (or periodic re-read)
- [ ] Ignore comments and empty lines

### Country Blocklist (`src/security/block_country.zig`)
- [ ] Load countries from `data/block_country.txt`
- [ ] `isBlocked(country) -> bool`
- [ ] Hot-reload on file change (or periodic re-read)
- [ ] Case-insensitive matching

### Middleware Chain Wiring (`src/server.zig`)
- [ ] Define `Middleware` function signature
- [ ] Define `RequestContext` struct (ip, country, schema, provider, etc.)
- [ ] Wire chain: `ip_extract -> schema_detect -> block_check -> dispatch`
- [ ] Each middleware calls `next` to continue chain

### Tests
- [ ] IP extract: CF-Connecting-IP present -> use it
- [ ] IP extract: no CF headers -> fallback to X-Forwarded-For
- [ ] IP extract: IPv4-mapped IPv6 -> normalized
- [ ] Schema detect: `/v1/chat/completions` -> openai
- [ ] Schema detect: `/v1/messages` -> anthropic
- [ ] Schema detect: `:generateContent` -> gemini
- [ ] Schema detect: `x-api-key` header -> anthropic
- [ ] Block check: blocked IP -> 403
- [ ] Block check: blocked country -> 403
- [ ] Block check: clean request -> passes through

---

## Phase 9: Model List Endpoint

### Model List Handler
- [ ] `GET /v1/models` - return merged model list from all enabled, non-hidden providers
- [ ] Filter models by detected schema (only models from providers supporting that schema)
- [ ] Format response using schema's `formatModelList` vtable function
- [ ] `GET /v1/models/{model_id}` - return single model info or 404
- [ ] Format single model using schema's `formatModelInfo`

### Tests
- [ ] OpenAI schema: returns `{ data: [...] }` format
- [ ] Anthropic schema: returns Anthropic model format
- [ ] Gemini schema: returns `{ models: [...] }` format
- [ ] Hidden provider models excluded
- [ ] Disabled provider models excluded
- [ ] Single model lookup: exists -> model info
- [ ] Single model lookup: not found -> 404

---

## Phase 10: Integration & Polish

### Main Entry (`src/main.zig`)
- [ ] Load server config from `data/config.yml`
- [ ] Load providers from `data/providers/*.yml`
- [ ] Open database, run migrations
- [ ] Initialize provider rows in DB
- [ ] Build model registry
- [ ] Initialize memory (sessions, key tracking)
- [ ] Build middleware chain
- [ ] Start HTTP server on configured port
- [ ] Graceful shutdown on SIGTERM/SIGINT

### Startup Logging
- [ ] Print loaded providers with model counts
- [ ] Print total registry size
- [ ] Print listen address

### Error Handling Audit
- [ ] Model not found -> 400 in client's schema format
- [ ] Provider doesn't support detected schema -> 400
- [ ] All keys saturated -> 503
- [ ] Upstream timeout -> timeout error in schema format
- [ ] Malformed request body -> 400
- [ ] No unhandled panics in request path

### End-to-End Tests
- [ ] `POST /v1/chat/completions` with OpenAI-format body routes correctly
- [ ] `POST /v1/messages` with Anthropic-format body routes correctly
- [ ] `GET /v1/models` returns merged list
- [ ] SSE streaming works end-to-end
- [ ] Key rotation on upstream 429
- [ ] Client disconnect aborts upstream cleanly

---

## Utilities

### Logger (`src/utils/logger.zig`)
- [ ] Console logger with colored output
- [ ] `info`, `warn`, `error`, `debug` levels
- [ ] `entry(key, schema, provider, endpoint)` - request entry log
- [ ] `completion(key, schema, path, duration, tokens)` - request completion log
- [ ] `retry(key, count, max)` - retry log
- [ ] `fail(key, msg)` - failure log

### Time (`src/utils/time.zig`)
- [ ] `parseDuration("10s") -> ms` - parse duration string to milliseconds
- [ ] `msToHuman(ms) -> "1 minute 5 seconds"` - human-readable duration

### Route Matching (`src/utils/route.zig` -- may not be needed with unified endpoints)
- [ ] Provider path matching (longest prefix first) -- only if needed for edge cases

### Tests
- [ ] `parseDuration`: "10s" -> 10000, "5m" -> 300000, "1h" -> 3600000
- [ ] `msToHuman`: 65000 -> "1 minute 5 seconds"

---

## Deferred (Not in Current Scope)

These are tracked here so they don't get lost. Implement as middleware or separate modules when needed.

- [ ] User auth system (tokens, tiers, permissions)
- [ ] Rate limiting middleware
- [ ] Request/response logging middleware
- [ ] Payload fingerprinting middleware
- [ ] Request spike detection middleware
- [ ] Chinese payload detection middleware
- [ ] Header-based ban rules middleware
- [ ] Bait response middleware
- [ ] Request rewriting middleware
- [ ] Response caching middleware
- [ ] Schema translation (OpenAI <-> Anthropic format conversion)
- [ ] Image generation endpoint handling
- [ ] Dynamic model fetching from provider APIs (currently uses `override.models`)
- [ ] Provider health check scripts (checker modules)
- [ ] Admin API routes
- [ ] Health check endpoint
- [ ] WebSocket dashboard
- [ ] CIDR range blocking
- [ ] Cloudflare Turnstile verification
- [ ] MOTD manager
- [ ] Preflight scripts (request body mutation)
- [ ] Response validation scripts
- [ ] Error validation scripts
- [ ] File logger (structured logging to disk)
