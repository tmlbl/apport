const std = @import("std");

fn dateCmdAlloc(a: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = a,
        .argv = args,
    });
    defer a.free(result.stderr);
    defer a.free(result.stdout);

    if (result.term.Exited != 0) {
        return error.DateCommandFailed;
    }

    // trim newline
    return a.dupe(u8, result.stdout[0 .. result.stdout.len - 1]);
}

/// Run the "date" command as a subprocess to generate a sortable date
/// tag, e.g. 2025_07_30
pub fn dateTagAlloc(a: std.mem.Allocator) ![]const u8 {
    return dateCmdAlloc(a, &.{ "date", "+%Y_%m_%d" });
}

/// Precise UTC timestamp for OCI image "created" field
pub fn createdTimeAlloc(a: std.mem.Allocator) ![]const u8 {
    return dateCmdAlloc(a, &.{ "date", "--utc", "+%Y-%m-%dT%H:%M:%S.%NZ" });
}

test "get a date tag" {
    const tag = try dateTagAlloc(std.testing.allocator);
    defer std.testing.allocator.free(tag);

    try std.testing.expectEqual(10, tag.len);
}
