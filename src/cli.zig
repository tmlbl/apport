const std = @import("std");
const cli = @import("./cli/root.zig");

pub fn main() !void {
    var rootCmd = try cli.getRootCmd();
    rootCmd.exec(std.os.argv) catch |err| {
        std.debug.print("error: {}\n", .{err});
        std.process.exit(1);
    };
}
