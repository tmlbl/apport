const std = @import("std");
const Cmd = @import("./Cmd.zig");
const ApiClient = @import("./ApiClient.zig");

pub fn initCmdFn(_: Cmd.Context) !void {
    const api = ApiClient{
        .a = std.heap.page_allocator,
    };

    const cwd = std.fs.cwd();
    const contents = try cwd.readFileAlloc(
        std.heap.page_allocator,
        "./Dockerfile",
        8192,
    );
    defer std.heap.page_allocator.free(contents);

    const parsedConfig = try api.initProject(.{
        .dockerfileContents = contents,
        .projectName = "test",
    });
    std.debug.print("got config\n", .{});
    parsedConfig.deinit();
}

pub fn getInitCmd() !Cmd {
    return Cmd.init(.{
        .allocator = std.heap.page_allocator,
        .name = "init",
        .description = "Initialize a new Docker-based project",
        .run = initCmdFn,
    });
}
