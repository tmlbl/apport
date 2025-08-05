const std = @import("std");
const Cmd = @import("./Cmd.zig");

const init = @import("./init.zig");

fn rootCmdFn(_: Cmd.Context) !void {
    std.debug.print("welcome to apport\n", .{});
}

pub fn getRootCmd() !Cmd {
    var rootCmd = try Cmd.init(.{
        .allocator = std.heap.page_allocator,
        .name = "root",
        .description = "The root command",
        .run = rootCmdFn,
    });

    try rootCmd.addCmd(try init.getInitCmd());

    return rootCmd;
}
