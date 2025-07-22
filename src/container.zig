const std = @import("std");
const nix = std.os.linux;

pub fn runInContainer(a: std.mem.Allocator, rootfs: std.fs.Dir) !void {
    const pid = nix.fork();
    const pidt: i32 = @intCast(pid);

    if (pid == 0) {
        std.debug.print("child pid: {}\n", .{nix.getpid()});
        const rootPath = try rootfs.realpathAlloc(a, ".");
        defer a.free(rootPath);

        const rootPathZ = try a.alloc(u8, rootPath.len + 1);
        std.mem.copyForwards(u8, rootPathZ[0..rootPath.len], rootPath);
        rootPathZ[rootPath.len] = 0; // null-terminate

        const rootPathC: [*:0]u8 = @ptrCast(rootPathZ.ptr);

        std.debug.print("entering root: {s}\n", .{rootPath});
        // chdir
        const chdir_rc = nix.chdir(rootPathC);
        if (chdir_rc != 0) return error.ChdirFailed;

        // chroot
        const chroot_rc = nix.chroot(rootPathC);
        if (chroot_rc != 0) return error.ChrootFailed;

        try runProcess(a);
    } else {
        std.debug.print("parent: forked child with pid: {}\n", .{pid});
        var status: u32 = 0;
        const p = nix.waitpid(pidt, &status, 0);
        std.debug.print("child exited with code: {} {}\n", .{ status, p });
    }
}

fn runProcess(a: std.mem.Allocator) !void {
    var child = std.process.Child.init(&[_][]const u8{
        "/bin/sh",
        "-c",
        "apt-get update && apt-get install -y cowsay",
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
