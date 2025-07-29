const std = @import("std");
const nix = std.os.linux;

pub fn runInContainer(a: std.mem.Allocator, rootFsPath: []const u8, cmd: []const u8) !void {
    const pid = nix.fork();
    const pidt: i32 = @intCast(pid);

    if (pid == 0) {
        const rootPathZ = try a.alloc(u8, rootFsPath.len + 1);
        std.mem.copyForwards(u8, rootPathZ[0..rootFsPath.len], rootFsPath);
        rootPathZ[rootFsPath.len] = 0; // null-terminate

        const rootPathC: [*:0]u8 = @ptrCast(rootPathZ.ptr);

        std.debug.print("entering root: {s}\n", .{rootFsPath});
        // chdir
        const chdir_rc = nix.chdir(rootPathC);
        if (chdir_rc != 0) return error.ChdirFailed;

        // chroot
        const chroot_rc = nix.chroot(rootPathC);
        if (chroot_rc != 0) return error.ChrootFailed;

        // mount overlay

        try runProcess(a, cmd);
    } else {
        std.debug.print("parent: forked child with pid: {}\n", .{pid});
        var status: u32 = 0;
        const p = nix.waitpid(pidt, &status, 0);
        std.debug.print("child exited with code: {} {}\n", .{ status, p });
    }
}

fn runProcess(a: std.mem.Allocator, cmd: []const u8) !void {
    std.log.debug("running command: {s}", .{cmd});
    var child = std.process.Child.init(&[_][]const u8{
        "/bin/sh",
        "-c",
        cmd,
    }, a);

    var env = std.process.EnvMap.init(a);
    defer env.deinit();

    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", "/root");

    child.env_map = &env;

    child.stdout = std.io.getStdOut();
    child.stderr = std.io.getStdErr();

    try child.spawn();

    const result = try child.wait();
    std.debug.print("Process exited with {}\n", .{result.Exited});
}
