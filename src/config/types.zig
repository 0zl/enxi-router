const std = @import("std");

/// API schema type -- determines auth, path matching, SSE format, model list format.
pub const SchemaType = enum {
    openai,
    anthropic,
    gemini,
};

/// Endpoint classification.
pub const EndpointType = enum {
    chat_completion,
    image_generation,
    passthrough,
};

/// API key lifecycle state.
pub const KeyState = enum {
    active,
    ratelimited,
    @"error",
    disabled,

    pub fn fromString(s: []const u8) ?KeyState {
        return std.meta.stringToEnum(KeyState, s);
    }

    pub fn toString(self: KeyState) []const u8 {
        return @tagName(self);
    }
};

/// Header stripping mode for upstream requests.
pub const StripMode = enum {
    /// Remove all non-essential headers.
    full,
    /// Keep most headers, only strip internal/proxy ones.
    minimal,
};

// ---------------------------------------------------------------------------
// Provider configuration (loaded from YAML)
// ---------------------------------------------------------------------------

/// A provider definition. One provider can serve multiple schemas and models.
/// Loaded from `data/providers/<name>.yml`.
pub const Provider = struct {
    id: []const u8,
    keys_id: []const u8,
    enable: bool = true,
    hidden: bool = false,
    require_auth: bool = false,
    priority: u32 = 0,
    endpoint: EndpointConfig,
    schemas: []const SchemaConfig,
    limit: PayloadLimit = .{},
    concurrency: ConcurrencyConfig = .{},
    override: OverrideConfig = .{},
    filter_models: ?[]const []const u8 = null,
    remap_models: ?[]const ModelRemap = null,
    cooldown: CooldownConfig,
    stream: ?StreamConfig = null,
};

/// Per-schema configuration within a provider.
/// Defines how to reach the upstream API for this schema.
pub const SchemaConfig = struct {
    id: SchemaType,
    /// Override base URL for this schema (e.g., zai anthropic uses a different host).
    base: ?[]const u8 = null,
    /// Path prefix prepended to upstream requests (e.g., "/v1", "/anthropic").
    upstream_path: []const u8 = "",
    /// Strip this prefix from the client path before appending to upstream_path.
    strip_path: ?[]const u8 = null,
};

/// Upstream endpoint URLs.
pub const EndpointConfig = struct {
    /// Primary upstream base URL.
    default: []const u8,
    /// Additional named endpoints (e.g., "coding", "regular").
    named: ?std.StringHashMap([]const u8) = null,
};

/// Token limits for request validation.
pub const PayloadLimit = struct {
    input: u32 = 65536,
    output: u32 = 8192,
};

/// Concurrency control per provider.
pub const ConcurrencyConfig = struct {
    /// Max concurrent requests per identity (IP/user).
    identity: u32 = 1,
    keys: KeyConcurrencyConfig = .{},
};

/// Per-key concurrency settings.
pub const KeyConcurrencyConfig = struct {
    /// Max concurrent requests using the same API key.
    same_key: u32 = 1,
    /// Max total requests before rotating to a different key.
    max_usage_same_key: u32 = 1,
    /// Keep the key active even after max_usage is reached.
    key_stay_active: bool = false,
};

/// Header, path, and model overrides for upstream requests.
pub const OverrideConfig = struct {
    headers: ?[]const HeaderOverride = null,
    path: ?[]const PathOverride = null,
    /// Hardcoded model list. When non-empty, skip API model fetching.
    models: ?[]const []const u8 = null,
    strip_mode: StripMode = .full,
};

/// A header to set on upstream requests.
pub const HeaderOverride = struct {
    key: []const u8,
    value: []const u8,
};

/// A path-specific override (e.g., block certain paths with a status code).
pub const PathOverride = struct {
    path: []const u8,
    status: u16,
};

/// Maps a client-facing model ID to a different upstream model ID.
pub const ModelRemap = struct {
    client: []const u8,
    upstream: []const u8,
};

/// Cooldown durations applied after requests.
pub const CooldownConfig = struct {
    /// Default cooldown (e.g., "10s").
    default: []const u8 = "10s",
    /// Schema-specific cooldown override (e.g., "35s" for chat_completion).
    chat_completion: ?[]const u8 = null,
};

/// Streaming behavior configuration.
pub const StreamConfig = struct {
    /// Fix malformed SSE event boundaries from upstream.
    sse_reframe: bool = false,
    /// Inject SSE keepalive comments at this interval (e.g., "15s").
    sse_keepalive: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Server configuration (loaded from data/config.yml)
// ---------------------------------------------------------------------------

pub const ServerConfig = struct {
    port: u16 = 8080,
    max_retry_count: u32 = 10,
};

// ---------------------------------------------------------------------------
// Runtime types
// ---------------------------------------------------------------------------

/// API key data from the database.
pub const KeyData = struct {
    id: i64,
    keys_id: []const u8,
    key: []const u8,
    state: KeyState,
    total_used: u32,
};
