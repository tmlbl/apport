const std = @import("std");

/// Minimal command-line tool framework
const Cmd = @This();

pub const Options = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    description: ?[]const u8 = "",
    run: RunFunction,
};

/// The contextual data available when a command function is executed
pub const Context = struct {};

pub const RunFunction = *const fn (Context) anyerror!void;

opts: Options,
subCmds: std.ArrayList(Cmd),

pub fn init(opts: Options) !Cmd {
    return Cmd{
        .opts = opts,
        .subCmds = std.ArrayList(Cmd).init(opts.allocator),
    };
}

pub fn deinit(self: *Cmd) void {
    self.subCmds.deinit();
}

pub fn addCmd(self: *Cmd, cmd: Cmd) !void {
    try self.subCmds.append(cmd);
}

pub fn exec(self: *Cmd, argv: [][*:0]u8) !void {
    if (argv.len == 1) {
        const ctx = Context{};
        try self.opts.run(ctx);
    } else {
        for (self.subCmds.items) |cmd| {
            const arg = std.mem.sliceTo(argv[1], 0);
            if (std.mem.eql(u8, arg, cmd.opts.name)) {
                const ctx = Context{};
                try cmd.opts.run(ctx);
            }
        }
    }
}

fn testCmdFn(_: Context) void {
    std.debug.print("test command\n", .{});
}

test "create a command" {
    var rootCmd = try Cmd.init(.{
        .allocator = std.testing.allocator,
        .name = "root",
        .description = "test root command",
        .run = testCmdFn,
    });
    defer rootCmd.deinit();

    try rootCmd.exec(&.{});
}
