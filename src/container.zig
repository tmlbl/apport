const std = @import("std");
const nix = std.os.linux;
const random = @import("./random.zig");

a: std.mem.Allocator,
id: []const u8,
rootFsPath: []const u8,

pub fn init(a: std.mem.Allocator, rootFsPath: []const u8) !@This() {
    const this = @This(){
        .a = a,
        .id = try random.randomCharsAlloc(a, 13),
        .rootFsPath = try a.dupe(u8, rootFsPath),
    };
    try this.initOverlayFs();
    return this;
}

pub fn deinit(self: @This()) void {
    self.a.free(self.id);
    self.a.free(self.rootFsPath);
}

pub fn runInContainer(self: @This(), stageNum: usize, cmd: []const u8) !void {
    std.log.info("stage: {d} cmd: {s}", .{ stageNum, cmd });
    try self.mountOverlayFs(stageNum);
    const merged = try self.mergedPath();
    defer self.a.free(merged);

    const pid = nix.fork();
    const pidt: i32 = @intCast(pid);

    if (pid == 0) {
        const rootPathC: [*:0]u8 = @ptrCast(merged.ptr);

        // std.debug.print("entering root: {s}\n", .{merged});
        // chdir
        const chdir_rc = nix.chdir(rootPathC);
        if (chdir_rc != 0) return error.ChdirFailed;

        // chroot
        const chroot_rc = nix.chroot(rootPathC);
        if (chroot_rc != 0) return error.ChrootFailed;

        try runProcess(self.a, cmd);
        std.process.exit(0);
    } else {
        std.debug.print("PARENT: forked child with pid: {}\n", .{pid});
        var status: u32 = 0;
        const p = nix.waitpid(pidt, &status, 0);
        if (status != 0) {
            std.log.err("child exited non-zero: {d}", .{status});
            return error.BuildStepFailed;
        }
        std.debug.print("PARENT: child exited with code: {} {}\n", .{ status, p });
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

    try env.put("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
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

fn initOverlayFs(self: @This()) !void {
    const buildDirPath = try std.fmt.allocPrint(
        self.a,
        "/tmp/apport-builds/{s}",
        .{self.id},
    );
    defer self.a.free(buildDirPath);

    std.debug.print("build dir: {s}\n", .{buildDirPath});

    try std.fs.makeDirAbsolute(buildDirPath);
    const buildDir = try std.fs.openDirAbsolute(buildDirPath, .{});
    try buildDir.makePath("merged");
}

fn mountOverlayFs(self: @This(), stageNum: usize) !void {
    const upper = try std.fmt.allocPrint(
        self.a,
        "/tmp/apport-builds/{s}/upper-{d}",
        .{ self.id, stageNum },
    );
    defer self.a.free(upper);
    std.debug.print("create upper {s}\n", .{upper});
    try std.fs.makeDirAbsolute(upper);

    const work = try std.fmt.allocPrint(
        self.a,
        "/tmp/apport-builds/{s}/work-{d}",
        .{ self.id, stageNum },
    );
    defer self.a.free(work);
    std.debug.print("create work {s}\n", .{work});
    try std.fs.makeDirAbsolute(work);

    var lowerDirs = std.ArrayList([]const u8).init(self.a);

    // Previous upper dirs become part of lower dir list
    if (stageNum > 0) {
        var i: usize = 0;
        while (i < stageNum) : (i += 1) {
            const prevUpper = try std.fmt.allocPrint(
                self.a,
                "/tmp/apport-builds/{s}/upper-{d}",
                .{ self.id, i },
            );

            std.debug.print("appending {s}\n", .{prevUpper});

            try lowerDirs.append(prevUpper);
        }
    }

    try lowerDirs.append(self.rootFsPath);

    const lowerSlice = try lowerDirs.toOwnedSlice();
    defer self.a.free(lowerSlice);

    const lower = try std.mem.join(self.a, ":", lowerSlice);
    defer self.a.free(lower);

    std.debug.print("lower dir: {s}\n", .{lower});

    const mountOptsStr = try std.fmt.allocPrintZ(
        self.a,
        "lowerdir={s},upperdir={s},workdir={s}",
        .{ lower, upper, work },
    );
    defer self.a.free(mountOptsStr);

    std.debug.print("mount options: {s}\n", .{mountOptsStr});

    const merged = try self.mergedPath();
    defer self.a.free(merged);

    const mountOpts: usize = @intFromPtr(mountOptsStr.ptr);

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
