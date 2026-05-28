const std = @import("std");
const yaml = @import("yaml");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Max size for a single YAML config file (256 KiB).
const max_file_size: Io.Limit = .limited(256 * 1024);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Load server configuration from a YAML file.
pub fn loadServerConfig(arena: Allocator, path: []const u8) !types.ServerConfig {
    const page = std.heap.page_allocator;
    var threaded = Io.Threaded.init(page, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const source = Dir.cwd().readFileAlloc(io, path, page, max_file_size) catch |err| {
        std.log.warn("failed to read server config '{s}': {}", .{ path, err });
        return .{};
    };
    defer page.free(source);

    return parseServerConfig(arena, source);
}

/// Load all provider configurations from a directory of YAML files.
pub fn loadProviders(arena: Allocator, dir_path: []const u8) ![]const types.Provider {
    const page = std.heap.page_allocator;
    var threaded = Io.Threaded.init(page, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("failed to open provider directory '{s}': {}", .{ dir_path, err });
        return try arena.alloc(types.Provider, 0);
    };
    defer dir.close(io);

    var providers: std.ArrayListUnmanaged(types.Provider) = .empty;

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isYamlFile(entry.name)) continue;

        const source = dir.readFileAlloc(io, entry.name, page, max_file_size) catch |err| {
            std.log.warn("failed to read provider file '{s}': {}", .{ entry.name, err });
            continue;
        };
        defer page.free(source);

        const provider = parseProviderYaml(arena, source) catch |err| {
            std.log.warn("failed to parse provider '{s}': {}", .{ entry.name, err });
            continue;
        };

        try providers.append(arena, provider);
    }

    return try providers.toOwnedSlice(arena);
}

/// Parse a single provider from a YAML source string.
/// The returned Provider's lifetime is tied to `arena`.
pub fn parseProviderYaml(arena: Allocator, source: []const u8) !types.Provider {
    const page = std.heap.page_allocator;

    var y = yaml.Yaml{ .source = source };
    try y.load(page);
    defer y.deinit(page);

    const yaml_file = try y.parse(arena, YamlProviderFile);
    return convertProvider(yaml_file.provider);
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn parseServerConfig(arena: Allocator, source: []const u8) !types.ServerConfig {
    const page = std.heap.page_allocator;

    var y = yaml.Yaml{ .source = source };
    try y.load(page);
    defer y.deinit(page);

    const config = try y.parse(arena, YamlServerFile);

    return .{
        .port = config.server.port,
        .max_retry_count = config.server.max_retry_count,
    };
}

fn isYamlFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".yml") or std.mem.endsWith(u8, name, ".yaml");
}

fn optBool(v: ?bool, default: bool) bool {
    return v orelse default;
}

fn convertProvider(yp: YamlProvider) !types.Provider {
    if (yp.id.len == 0) return error.InvalidProviderId;
    if (yp.schema.len == 0) return error.NoSchemasDefined;

    const override: YamlOverride = yp.override orelse .{};
    const concurrency: YamlConcurrency = yp.concurrency orelse .{};
    const keys: YamlKeyConcurrency = concurrency.keys orelse .{};

    return .{
        .id = yp.id,
        .keys_id = yp.keys_id,
        .enable = optBool(yp.enable, true),
        .hidden = optBool(yp.hidden, false),
        .require_auth = optBool(yp.require_auth, false),
        .priority = yp.priority,
        .endpoint = .{
            .default = yp.endpoint.default,
            .named = null,
        },
        .schemas = yp.schema,
        .limit = if (yp.limit) |l| (l.payload orelse .{}) else .{},
        .concurrency = .{
            .identity = concurrency.identity,
            .keys = .{
                .same_key = keys.same_key,
                .max_usage_same_key = keys.max_usage_same_key,
                .key_stay_active = optBool(keys.key_stay_active, false),
            },
        },
        .override = .{
            .headers = override.headers,
            .path = override.path,
            .models = override.models,
            .strip_mode = override.strip_mode,
        },
        .filter_models = if (yp.filter_models) |fm| (if (fm.len > 0) fm else null) else null,
        .remap_models = yp.remap_models,
        .cooldown = yp.cooldown orelse .{},
        .stream = if (yp.stream) |s| types.StreamConfig{
            .sse_reframe = optBool(s.sse_reframe, false),
            .sse_keepalive = s.sse_keepalive,
        } else null,
    };
}

// ---------------------------------------------------------------------------
// YAML parsing structs
//
// These match the YAML structure. We cannot reuse domain types directly
// because zig-yaml's parseBoolean does not handle the .boolean variant
// produced by Value.encode for default bool values. Using ?bool avoids
// this: when the field is absent, parseOptional returns null without
// going through parseBoolean.
// ---------------------------------------------------------------------------

const YamlServerFile = struct {
    server: YamlServerSection = .{},
};

const YamlServerSection = struct {
    port: u16 = 8080,
    max_retry_count: u32 = 10,
};

const YamlProviderFile = struct {
    provider: YamlProvider,
};

const YamlProvider = struct {
    id: []const u8,
    keys_id: []const u8,
    enable: ?bool = null,
    hidden: ?bool = null,
    require_auth: ?bool = null,
    priority: u32 = 0,
    endpoint: YamlEndpoint,
    schema: []const types.SchemaConfig,
    limit: ?YamlLimit = null,
    concurrency: ?YamlConcurrency = null,
    override: ?YamlOverride = null,
    filter_models: ?[]const []const u8 = null,
    remap_models: ?[]const types.ModelRemap = null,
    cooldown: ?types.CooldownConfig = null,
    stream: ?YamlStream = null,
};

const YamlEndpoint = struct {
    default: []const u8,
};

const YamlLimit = struct {
    payload: ?types.PayloadLimit = null,
};

const YamlConcurrency = struct {
    identity: u32 = 1,
    keys: ?YamlKeyConcurrency = null,
};

const YamlKeyConcurrency = struct {
    same_key: u32 = 1,
    max_usage_same_key: u32 = 1,
    key_stay_active: ?bool = null,
};

const YamlOverride = struct {
    headers: ?[]const types.HeaderOverride = null,
    path: ?[]const types.PathOverride = null,
    models: ?[]const []const u8 = null,
    strip_mode: types.StripMode = .full,
};

const YamlStream = struct {
    sse_reframe: ?bool = null,
    sse_keepalive: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "config: parse openai provider" {
    const source =
        \\provider:
        \\  id: openai
        \\  keys_id: openai
        \\  enable: false
        \\  hidden: true
        \\  require_auth: true
        \\  endpoint:
        \\    default: https://api.openai.com
        \\  schema:
        \\    - id: openai
        \\      upstream_path: /v1
        \\  limit:
        \\    payload:
        \\      input: 65536
        \\      output: 8192
        \\  concurrency:
        \\    identity: 1
        \\    keys:
        \\      same_key: 1
        \\      max_usage_same_key: 1
        \\  override:
        \\    strip_mode: minimal
        \\    headers:
        \\      - key: user-agent
        \\        value: "Kilo-Code/5.7.0"
        \\    path: []
        \\    models: []
        \\  filter_models: []
        \\  cooldown:
        \\    default: 10s
        \\    chat_completion: 50s
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const p = try parseProviderYaml(arena, source);

    try std.testing.expectEqualStrings("openai", p.id);
    try std.testing.expectEqualStrings("openai", p.keys_id);
    try std.testing.expectEqual(false, p.enable);
    try std.testing.expectEqual(true, p.hidden);
    try std.testing.expectEqual(true, p.require_auth);
    try std.testing.expectEqual(@as(u32, 0), p.priority);

    // Endpoint
    try std.testing.expectEqualStrings("https://api.openai.com", p.endpoint.default);
    try std.testing.expect(p.endpoint.named == null);

    // Schemas
    try std.testing.expectEqual(@as(usize, 1), p.schemas.len);
    try std.testing.expectEqual(types.SchemaType.openai, p.schemas[0].id);
    try std.testing.expectEqualStrings("/v1", p.schemas[0].upstream_path);
    try std.testing.expect(p.schemas[0].base == null);
    try std.testing.expect(p.schemas[0].strip_path == null);

    // Limits
    try std.testing.expectEqual(@as(u32, 65536), p.limit.input);
    try std.testing.expectEqual(@as(u32, 8192), p.limit.output);

    // Concurrency
    try std.testing.expectEqual(@as(u32, 1), p.concurrency.identity);
    try std.testing.expectEqual(@as(u32, 1), p.concurrency.keys.same_key);
    try std.testing.expectEqual(@as(u32, 1), p.concurrency.keys.max_usage_same_key);

    // Override
    try std.testing.expectEqual(types.StripMode.minimal, p.override.strip_mode);
    try std.testing.expect(p.override.headers != null);
    try std.testing.expectEqual(@as(usize, 1), p.override.headers.?.len);
    try std.testing.expectEqualStrings("user-agent", p.override.headers.?[0].key);
    try std.testing.expectEqualStrings("Kilo-Code/5.7.0", p.override.headers.?[0].value);

    // filter_models: [] -> normalized to null
    try std.testing.expect(p.filter_models == null);

    // Cooldown
    try std.testing.expectEqualStrings("10s", p.cooldown.default);
    try std.testing.expectEqualStrings("50s", p.cooldown.chat_completion.?);

    // Stream (not set)
    try std.testing.expect(p.stream == null);
}

test "config: parse deepseek provider" {
    const source =
        \\provider:
        \\  id: deepseek
        \\  keys_id: deepseek
        \\  enable: true
        \\  hidden: false
        \\  require_auth: false
        \\  priority: 10
        \\  endpoint:
        \\    default: https://api.deepseek.com
        \\  schema:
        \\    - id: openai
        \\      upstream_path: /v1
        \\    - id: anthropic
        \\      upstream_path: /anthropic
        \\  limit:
        \\    payload:
        \\      input: 73728
        \\      output: 16384
        \\  concurrency:
        \\    identity: 1
        \\    keys:
        \\      same_key: 2
        \\      max_usage_same_key: 4
        \\  override:
        \\    headers:
        \\      - key: user-agent
        \\        value: "claude-cli/2.1.12"
        \\      - key: anthropic-version
        \\        value: "2023-06-01"
        \\    path:
        \\      - path: /user/balance
        \\        status: 403
        \\    models: ["deepseek-v4-flash", "deepseek-v4-pro"]
        \\  filter_models: []
        \\  cooldown:
        \\    default: 10s
        \\    chat_completion: 35s
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const p = try parseProviderYaml(arena, source);

    try std.testing.expectEqualStrings("deepseek", p.id);
    try std.testing.expectEqual(true, p.enable);
    try std.testing.expectEqual(false, p.hidden);
    try std.testing.expectEqual(@as(u32, 10), p.priority);

    // Multi-schema
    try std.testing.expectEqual(@as(usize, 2), p.schemas.len);
    try std.testing.expectEqual(types.SchemaType.openai, p.schemas[0].id);
    try std.testing.expectEqualStrings("/v1", p.schemas[0].upstream_path);
    try std.testing.expectEqual(types.SchemaType.anthropic, p.schemas[1].id);
    try std.testing.expectEqualStrings("/anthropic", p.schemas[1].upstream_path);

    // Limits
    try std.testing.expectEqual(@as(u32, 73728), p.limit.input);
    try std.testing.expectEqual(@as(u32, 16384), p.limit.output);

    // Concurrency
    try std.testing.expectEqual(@as(u32, 2), p.concurrency.keys.same_key);
    try std.testing.expectEqual(@as(u32, 4), p.concurrency.keys.max_usage_same_key);

    // Override
    try std.testing.expectEqual(types.StripMode.full, p.override.strip_mode); // default
    try std.testing.expectEqual(@as(usize, 2), p.override.headers.?.len);
    try std.testing.expectEqual(@as(usize, 1), p.override.path.?.len);
    try std.testing.expectEqualStrings("/user/balance", p.override.path.?[0].path);
    try std.testing.expectEqual(@as(u16, 403), p.override.path.?[0].status);

    // Models
    try std.testing.expect(p.override.models != null);
    try std.testing.expectEqual(@as(usize, 2), p.override.models.?.len);
    try std.testing.expectEqualStrings("deepseek-v4-flash", p.override.models.?[0]);
    try std.testing.expectEqualStrings("deepseek-v4-pro", p.override.models.?[1]);
}

test "config: parse zai provider" {
    const source =
        \\provider:
        \\  id: zai
        \\  keys_id: zai
        \\  enable: true
        \\  hidden: false
        \\  require_auth: false
        \\  priority: 5
        \\  endpoint:
        \\    default: https://api.z.ai/api/paas
        \\    regular: https://api.z.ai/api/paas
        \\    coding: https://api.z.ai/api/coding/paas
        \\  schema:
        \\    - id: openai
        \\      upstream_path: /v4
        \\      strip_path: /v1
        \\    - id: anthropic
        \\      base: https://api.z.ai/api
        \\      upstream_path: /anthropic
        \\  limit:
        \\    payload:
        \\      input: 65536
        \\      output: 32768
        \\  concurrency:
        \\    identity: 1
        \\    keys:
        \\      same_key: 2
        \\      max_usage_same_key: 1
        \\  override:
        \\    strip_mode: minimal
        \\    headers:
        \\      - key: user-agent
        \\        value: "claude-cli/1.0.2456"
        \\    path: []
        \\    models:
        \\      - glm-4.6
        \\      - glm-4.7
        \\  filter_models: []
        \\  cooldown:
        \\    default: 10s
        \\    chat_completion: 35s
        \\  stream:
        \\    sse_reframe: true
        \\    sse_keepalive: 15s
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const p = try parseProviderYaml(arena, source);

    try std.testing.expectEqualStrings("zai", p.id);
    try std.testing.expectEqual(@as(u32, 5), p.priority);

    // Endpoint (only default captured, named ignored)
    try std.testing.expectEqualStrings("https://api.z.ai/api/paas", p.endpoint.default);

    // Schema with strip_path and base override
    try std.testing.expectEqual(@as(usize, 2), p.schemas.len);
    try std.testing.expectEqual(types.SchemaType.openai, p.schemas[0].id);
    try std.testing.expectEqualStrings("/v4", p.schemas[0].upstream_path);
    try std.testing.expectEqualStrings("/v1", p.schemas[0].strip_path.?);
    try std.testing.expectEqual(types.SchemaType.anthropic, p.schemas[1].id);
    try std.testing.expectEqualStrings("https://api.z.ai/api", p.schemas[1].base.?);
    try std.testing.expectEqualStrings("/anthropic", p.schemas[1].upstream_path);

    // Override models
    try std.testing.expectEqual(@as(usize, 2), p.override.models.?.len);
    try std.testing.expectEqualStrings("glm-4.6", p.override.models.?[0]);
    try std.testing.expectEqualStrings("glm-4.7", p.override.models.?[1]);

    // Stream config
    try std.testing.expect(p.stream != null);
    try std.testing.expectEqual(true, p.stream.?.sse_reframe);
    try std.testing.expectEqualStrings("15s", p.stream.?.sse_keepalive.?);
}

test "config: parse gemini-flash provider" {
    const source =
        \\provider:
        \\  id: gemini/flash
        \\  keys_id: gemini
        \\  enable: true
        \\  hidden: false
        \\  require_auth: true
        \\  endpoint:
        \\    default: https://generativelanguage.googleapis.com
        \\  schema:
        \\    - id: gemini
        \\      upstream_path: /v1beta
        \\    - id: openai
        \\      upstream_path: /v1beta/openai
        \\  limit:
        \\    payload:
        \\      input: 65536
        \\      output: 4096
        \\  concurrency:
        \\    identity: 1
        \\    keys:
        \\      same_key: 1
        \\      max_usage_same_key: 3
        \\  override:
        \\    strip_mode: minimal
        \\    headers: []
        \\    path: []
        \\    models: []
        \\  filter_models:
        \\    - models/gemini-3-flash-preview
        \\    - gemini-3-flash-preview
        \\    - models/gemma-4-31b-it
        \\    - gemma-4-31b-it
        \\  cooldown:
        \\    default: 10s
        \\    chat_completion: 45s
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const p = try parseProviderYaml(arena, source);

    try std.testing.expectEqualStrings("gemini/flash", p.id);
    try std.testing.expectEqualStrings("gemini", p.keys_id);

    // Schemas
    try std.testing.expectEqual(@as(usize, 2), p.schemas.len);
    try std.testing.expectEqual(types.SchemaType.gemini, p.schemas[0].id);
    try std.testing.expectEqualStrings("/v1beta", p.schemas[0].upstream_path);
    try std.testing.expectEqual(types.SchemaType.openai, p.schemas[1].id);
    try std.testing.expectEqualStrings("/v1beta/openai", p.schemas[1].upstream_path);

    // Empty headers/models/path
    try std.testing.expectEqual(@as(usize, 0), p.override.headers.?.len);
    try std.testing.expectEqual(@as(usize, 0), p.override.models.?.len);

    // filter_models with actual entries
    try std.testing.expect(p.filter_models != null);
    try std.testing.expectEqual(@as(usize, 4), p.filter_models.?.len);
    try std.testing.expectEqualStrings("models/gemini-3-flash-preview", p.filter_models.?[0]);
    try std.testing.expectEqualStrings("gemma-4-31b-it", p.filter_models.?[3]);
}

test "config: defaults applied for minimal provider" {
    const source =
        \\provider:
        \\  id: minimal
        \\  keys_id: minimal
        \\  endpoint:
        \\    default: https://api.example.com
        \\  schema:
        \\    - id: openai
        \\  cooldown:
        \\    default: 5s
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const p = try parseProviderYaml(arena, source);

    try std.testing.expectEqual(true, p.enable);
    try std.testing.expectEqual(false, p.hidden);
    try std.testing.expectEqual(false, p.require_auth);
    try std.testing.expectEqual(@as(u32, 0), p.priority);

    // Schema defaults
    try std.testing.expectEqualStrings("", p.schemas[0].upstream_path);
    try std.testing.expect(p.schemas[0].base == null);
    try std.testing.expect(p.schemas[0].strip_path == null);

    // Limit defaults
    try std.testing.expectEqual(@as(u32, 65536), p.limit.input);
    try std.testing.expectEqual(@as(u32, 8192), p.limit.output);

    // Concurrency defaults
    try std.testing.expectEqual(@as(u32, 1), p.concurrency.identity);
    try std.testing.expectEqual(@as(u32, 1), p.concurrency.keys.same_key);

    // Override defaults
    try std.testing.expectEqual(types.StripMode.full, p.override.strip_mode);
    try std.testing.expect(p.override.headers == null);
    try std.testing.expect(p.override.models == null);

    // filter_models normalized to null
    try std.testing.expect(p.filter_models == null);
    try std.testing.expect(p.remap_models == null);
    try std.testing.expect(p.stream == null);
}

test "config: error on missing required fields" {
    const source =
        \\provider:
        \\  keys_id: test
        \\  endpoint:
        \\    default: https://api.example.com
        \\  schema:
        \\    - id: openai
        \\  cooldown:
        \\    default: 10s
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const result = parseProviderYaml(arena, source);
    try std.testing.expect(result == error.StructFieldMissing);
}

test "config: error on empty schema list" {
    const source =
        \\provider:
        \\  id: test
        \\  keys_id: test
        \\  endpoint:
        \\    default: https://api.example.com
        \\  schema: []
        \\  cooldown:
        \\    default: 10s
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const result = parseProviderYaml(arena, source);
    try std.testing.expect(result == error.NoSchemasDefined);
}

test "config: server config parsing" {
    const source =
        \\security:
        \\  verified_only:
        \\    enabled: false
        \\server:
        \\  port: 30180
        \\  max_retry_count: 5
        \\memory:
        \\  cleanup_interval_ms: 60000
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const cfg = try parseServerConfig(arena, source);

    try std.testing.expectEqual(@as(u16, 30180), cfg.port);
    try std.testing.expectEqual(@as(u32, 5), cfg.max_retry_count);
}

test "config: server config defaults when section missing" {
    const source =
        \\other_section:
        \\  foo: bar
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const cfg = try parseServerConfig(arena, source);

    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqual(@as(u32, 10), cfg.max_retry_count);
}

test "config: extra YAML fields are ignored" {
    const source =
        \\provider:
        \\  id: test
        \\  keys_id: test
        \\  endpoint:
        \\    default: https://api.example.com
        \\  schema:
        \\    - id: openai
        \\      upstream_path: /v1
        \\  cooldown:
        \\    default: 10s
        \\  pricing:
        \\    input:
        \\      value: 5
        \\      token_scale: 1000000
        \\  scripts:
        \\    checker: openai-compatible
        \\  page:
        \\    message: "hello world"
        \\  timeout:
        \\    idle: 10m
        \\  keys_metadata: []
        \\  display:
        \\    keys_count_label: "???"
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const p = try parseProviderYaml(arena, source);
    try std.testing.expectEqualStrings("test", p.id);
}

test "config: loadProviders from data directory" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const providers = try loadProviders(arena, "data/providers");

    // We expect at least 4 providers from our data files
    try std.testing.expect(providers.len >= 4);

    // Verify we can find specific providers by id
    var found_openai = false;
    var found_deepseek = false;
    var found_zai = false;
    var found_gemini = false;

    for (providers) |p| {
        if (std.mem.eql(u8, p.id, "openai")) {
            found_openai = true;
            try std.testing.expectEqual(false, p.enable);
            try std.testing.expectEqual(true, p.hidden);
        }
        if (std.mem.eql(u8, p.id, "deepseek")) {
            found_deepseek = true;
            try std.testing.expectEqual(@as(u32, 10), p.priority);
            try std.testing.expectEqual(@as(usize, 2), p.schemas.len);
        }
        if (std.mem.eql(u8, p.id, "zai")) {
            found_zai = true;
            try std.testing.expect(p.stream != null);
            try std.testing.expectEqual(true, p.stream.?.sse_reframe);
        }
        if (std.mem.eql(u8, p.id, "gemini/flash")) {
            found_gemini = true;
            try std.testing.expect(p.filter_models != null);
            try std.testing.expectEqual(@as(usize, 4), p.filter_models.?.len);
        }
    }

    try std.testing.expect(found_openai);
    try std.testing.expect(found_deepseek);
    try std.testing.expect(found_zai);
    try std.testing.expect(found_gemini);
}

test "config: loadServerConfig from data file" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const cfg = try loadServerConfig(arena, "data/config.yml");
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqual(@as(u32, 10), cfg.max_retry_count);
}
