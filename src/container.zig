const std = @import("std");
const nix = std.os.linux;
const random = @import("./random.zig");

a: std.mem.Allocator,
id: []const u8,
rootFsPath: []const u8,

pub fn init(a: std.mem.Allocator, rootFsPath: []const u8) !@This() {
    return @This(){
        .a = a,
        .id = try random.randomCharsAlloc(a, 13),
        .rootFsPath = try a.dupe(u8, rootFsPath),
    };
}

pub fn deinit(self: @This()) void {
    self.a.free(self.id);
    self.a.free(self.rootFsPath);
}

pub fn runInContainer(self: @This(), cmd: []const u8) !void {
    try self.mountOverlayFs();
    const merged = try self.mergedPath();
    defer self.a.free(merged);

    const pid = nix.fork();
    const pidt: i32 = @intCast(pid);

    if (pid == 0) {
        const rootPathC: [*:0]u8 = @ptrCast(merged.ptr);

        std.debug.print("entering root: {s}\n", .{merged});
        // chdir
        const chdir_rc = nix.chdir(rootPathC);
        if (chdir_rc != 0) return error.ChdirFailed;

        // chroot
        const chroot_rc = nix.chroot(rootPathC);
        if (chroot_rc != 0) return error.ChrootFailed;

        try runProcess(self.a, cmd);
    } else {
        std.debug.print("parent: forked child with pid: {}\n", .{pid});
        var status: u32 = 0;
        const p = nix.waitpid(pidt, &status, 0);
        std.debug.print("child exited with code: {} {}\n", .{ status, p });
        try self.unmountOverlayFs();
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

fn mergedPath(self: @This()) ![:0]u8 {
    return std.fmt.allocPrintZ(
        self.a,
        "/tmp/apport-builds/{s}/merged",
        .{self.id},
    );
}

fn unmountOverlayFs(self: @This()) !void {
    const merged = try self.mergedPath();
    defer self.a.free(merged);

    const ret = nix.umount(merged.ptr);
    if (ret != 0) {
        return error.UmountFailed;
    }
}

fn mountOverlayFs(self: @This()) !void {
    const buildDirPath = try std.fmt.allocPrint(
        self.a,
        "/tmp/apport-builds/{s}",
        .{self.id},
    );
    defer self.a.free(buildDirPath);

    std.debug.print("build dir: {s}\n", .{buildDirPath});

    try std.fs.makeDirAbsolute(buildDirPath);
    const buildDir = try std.fs.openDirAbsolute(buildDirPath, .{});

    const upper = try std.fmt.allocPrint(
        self.a,
        "/tmp/apport-builds/{s}/upper",
        .{self.id},
    );
    defer self.a.free(upper);
    try buildDir.makePath("upper");

    const work = try std.fmt.allocPrint(
        self.a,
        "/tmp/apport-builds/{s}/work",
        .{self.id},
    );
    defer self.a.free(work);
    try buildDir.makePath("work");

    const mountOptsStr = try std.fmt.allocPrintZ(
        self.a,
        "lowerdir={s},upperdir={s},workdir={s}",
        .{ self.rootFsPath, upper, work },
    );
    defer self.a.free(mountOptsStr);

    const merged = try self.mergedPath();
    defer self.a.free(merged);
    try buildDir.makePath("merged");

    const mountOpts: usize = @intFromPtr(mountOptsStr.ptr);

    std.debug.print("mount options: {s}\n", .{mountOptsStr});

    const result = nix.mount(
        "overlay", // source
        merged.ptr, // target
        "overlay", // filesystem type
        0, // flags
        mountOpts, // data
    );
    if (result != 0) {
        return error.MountFailed;
    }
}
