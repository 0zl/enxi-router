const std = @import("std");
const types = @import("config/types.zig");
const httpz = @import("httpz");

pub fn main() !void {
    std.debug.print("enxi-router starting\n", .{});

    // Verify core types compile and are instantiable.
    const provider = types.Provider{
        .id = "test",
        .keys_id = "test",
        .endpoint = .{ .default = "https://api.example.com" },
        .schemas = &[_]types.SchemaConfig{
            .{ .id = .openai, .upstream_path = "/v1" },
        },
        .cooldown = .{ .default = "10s" },
    };
    _ = provider;

    const entry = types.KeyData{
        .id = 1,
        .keys_id = "test",
        .key = "sk-test-key",
        .state = .active,
        .total_used = 0,
    };
    _ = entry;

    std.debug.print("types verified\n", .{});
}

test "types: SchemaType" {
    const openai = types.SchemaType.openai;
    try std.testing.expectEqual(types.SchemaType.openai, openai);
}

test "types: KeyState fromString" {
    try std.testing.expectEqual(types.KeyState.active, types.KeyState.fromString("active").?);
    try std.testing.expectEqual(types.KeyState.ratelimited, types.KeyState.fromString("ratelimited").?);
    try std.testing.expect(types.KeyState.fromString("invalid") == null);
}

test "types: Provider instantiation" {
    const p = types.Provider{
        .id = "deepseek",
        .keys_id = "deepseek",
        .endpoint = .{ .default = "https://api.deepseek.com" },
        .schemas = &[_]types.SchemaConfig{
            .{ .id = .openai, .upstream_path = "/v1" },
            .{ .id = .anthropic, .upstream_path = "/anthropic" },
        },
        .override = .{
            .models = &[_][]const u8{ "deepseek-v4-flash", "deepseek-v4-pro" },
        },
        .cooldown = .{ .default = "10s", .chat_completion = "35s" },
    };
    try std.testing.expectEqualStrings("deepseek", p.id);
    try std.testing.expectEqual(@as(u32, 0), p.priority);
    try std.testing.expectEqual(types.StripMode.full, p.override.strip_mode);
}

test "types: ServerConfig defaults" {
    const cfg = types.ServerConfig{};
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqual(@as(u32, 10), cfg.max_retry_count);
}
