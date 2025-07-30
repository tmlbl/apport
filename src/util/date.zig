const std = @import("std");

/// Run the "date" command as a subprocess to generate a sortable date
/// tag, e.g. 2025_07_30
pub fn dateTagAlloc(a: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "date", "+%Y_%m_%d" },
    });
    defer a.free(result.stderr);
    defer a.free(result.stdout);

    if (result.term.Exited != 0) {
        return error.DateCommandFailed;
    }

    return a.dupe(u8, result.stdout[0..10]);
}

test "get a date tag" {
    const tag = try dateTagAlloc(std.testing.allocator);
    defer std.testing.allocator.free(tag);

    try std.testing.expectEqual(10, tag.len);
}
