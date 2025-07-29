const std = @import("std");
const oci = @import("ocispec");

const resolvConf =
    \\nameserver 8.8.8.8
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

    const parsed = try std.json.parseFromSlice(oci.image.Manifest, a, manData, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const manifest = parsed.value;

    const blobDir = try dir.openDir("blobs/sha256", .{});

    const targetPath = try target.realpathAlloc(a, ".");
    defer a.free(targetPath);

    // Unpack layers to the target directory
    for (manifest.layers) |layer| {
        std.debug.print("unpacking: {s}\n", .{layer.digest.value});

        const blobPath = try blobDir.realpathAlloc(a, layer.digest.value);
        defer a.free(blobPath);

        // Zig 0.14's std.tar works only with ustar format tar files.
        // If you're seeing error.TarHeader due to octal parsing, your tar likely uses GNU/PAX extensions.
        //var diag = std.tar.Diagnostics{
        //    .allocator = a,
        //};
        //defer diag.deinit();
        //try std.tar.pipeToFileSystem(target, blob.reader(), .{
        //    .diagnostics = &diag,
        //    .mode_mode = .ignore,
        //});

        var process = std.process.Child.init(&.{ "tar", "xf", blobPath }, a);
        process.cwd = targetPath;
        const result = try process.spawnAndWait();
        if (result.Exited != 0) {
            return error.TarFailed;
        }
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
    const result = std.os.linux.mknod(nullPathC, mode, dev);
    if (result != 0) {
        std.debug.print("mknod result: {d}\n", .{result});
        return error.MkNodFailed;
    }
}
