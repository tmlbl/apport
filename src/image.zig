const std = @import("std");

pub const Manifest = struct {
    Config: []const u8,
    RepoTags: []const []const u8,
    Layers: []const []const u8,
};

const Link = struct {
    link_name: []const u8,
    file_name: []const u8,
};

const resolvConf =
    \\nameserver 192.168.0.1
    \\options edns0
;

fn makedev(major: u64, minor: u64) u64 {
    return ((major & 0xfff) << 8) | (minor & 0xff) | ((minor & 0xfffff00) << 12);
}

// Progressively unpacks a Docker/OCI image file structure into a rootfs
pub fn image2rootfs(a: std.mem.Allocator, dir: std.fs.Dir, target: std.fs.Dir) !void {
    // Parse the manifest file
    const manFile = try dir.openFile("manifest.json", .{});
    defer manFile.close();

    const manData = try manFile.readToEndAlloc(a, 8096);
    defer a.free(manData);

    const parsed = try std.json.parseFromSlice([]const Manifest, a, manData, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const manifest = parsed.value[0];

    // Unpack layers to the target directory
    for (manifest.Layers) |layer| {
        std.debug.print("unpacking: {s}\n", .{layer});
        const blob = try dir.openFile(layer, .{});
        defer blob.close();

        const fnBuf = try a.alloc(u8, 4096);
        defer a.free(fnBuf);
        const lnBuf = try a.alloc(u8, 4096);
        defer a.free(lnBuf);

        var diag = std.tar.Diagnostics{
            .allocator = a,
        };
        defer diag.deinit();

        try std.tar.pipeToFileSystem(target, blob.reader(), .{
            .diagnostics = &diag,
        });
    }

    // Add resolv.conf
    const resolvFile = try target.createFile("etc/resolv.conf", .{});
    defer resolvFile.close();
    try resolvFile.writeAll(resolvConf);

    // Fix permissions for /tmp
    const tmpDir = try target.openDir("tmp", .{
        .iterate = true,
    });
    try tmpDir.chmod(0o1777);

    // Delete /dev/null and re-create with mknod
    const devPath = try target.realpathAlloc(a, "dev");
    defer a.free(devPath);
    const nullPath = try std.fs.path.join(a, &[_][]const u8{
        devPath, "null",
    });
    defer a.free(nullPath);
    std.debug.print("nullpath: {s}\n", .{nullPath});

    const nullPathC: [*:0]u8 = @ptrCast(nullPath.ptr);

    const prev_umask = std.c.umask(0);
    defer _ = std.c.umask(prev_umask); // restore

    const mode = 0o666 | std.os.linux.S.IFCHR;
    const dev: u32 = @intCast(makedev(1, 3));
    if (std.os.linux.mknod(nullPathC, mode, dev) != 0) {
        return error.MkNodFailed;
    }
}
