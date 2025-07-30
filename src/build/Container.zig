const std = @import("std");
const nix = std.os.linux;
const oci = @import("ocispec");
const random = @import("../util/random.zig");
const Stage = @import("./Stage.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

a: std.mem.Allocator,
id: []const u8,
stage: Stage,
imagePath: []const u8,
configuration: std.json.Parsed(oci.image.Configuration),
manifest: std.json.Parsed(oci.image.Manifest),
layers: std.ArrayList(oci.image.Descriptor),

pub fn init(a: std.mem.Allocator, stage: Stage, imagePath: []const u8) !@This() {
    // Load the image configuration
    const imageDir = try std.fs.openDirAbsolute(imagePath, .{});
    const configData = try imageDir.readFileAlloc(a, "config.json", 8192);
    defer a.free(configData);
    const parsedConfiguration = try std.json.parseFromSlice(
        oci.image.Configuration,
        a,
        configData,
        .{
            .ignore_unknown_fields = true,
        },
    );

    // Load the manifest
    const manData = try imageDir.readFileAlloc(a, "manifest.json", 8192);
    defer a.free(manData);
    const parsedManifest = try std.json.parseFromSlice(
        oci.image.Manifest,
        a,
        manData,
        .{},
    );

    var this = @This(){
        .a = a,
        .id = try random.randomCharsAlloc(a, 13),
        .stage = stage,
        .imagePath = try a.dupe(u8, imagePath),
        .configuration = parsedConfiguration,
        .manifest = parsedManifest,
        .layers = std.ArrayList(oci.image.Descriptor).init(a),
    };

    for (parsedManifest.value.layers) |descriptor| {
        try this.layers.append(descriptor);
    }

    try this.initOverlayFs();
    try std.fs.makeDirAbsolute(try this.resultDirPath());
    return this;
}

pub fn deinit(self: @This()) void {
    self.configuration.deinit();
    self.manifest.deinit();
    self.a.free(self.id);
    self.a.free(self.imagePath);
    self.layers.deinit();
}

pub fn run(self: *@This()) !void {
    var i: usize = 0;
    while (i < self.stage.steps.items.len) : (i += 1) {
        const step = self.stage.steps.items[i];

        switch (step.kind) {
            .run => try self.runInContainer(i, step.args),
            else => return error.NotImplemented,
        }
    }

    try self.commitImage();
}

fn commitImage(self: *@This()) !void {
    const resultDir = try std.fs.openDirAbsolute(try self.resultDirPath(), .{});

    // Write configuration
    const configuration = oci.image.Configuration{
        .architecture = .Amd64,
        .created = "doo",
        .os = .Linux,
        .rootfs = .{
            .type = "layers",
            .diff_ids = &.{},
        },
    };

    const confData = try std.json.stringifyAlloc(self.a, configuration, .{
        .emit_null_optional_fields = false,
    });
    defer self.a.free(confData);

    var hash = Sha256.init(.{});
    hash.update(confData);
    const digest = try std.fmt.allocPrint(
        self.a,
        "{s}",
        .{std.fmt.fmtSliceHexLower(&hash.finalResult())},
    );
    defer self.a.free(digest);

    const blobsDir = try resultDir.openDir("blobs/sha256", .{});
    const confFile = try blobsDir.createFile(digest, .{});
    defer confFile.close();
    try confFile.writeAll(confData);

    const manifest = oci.image.Manifest{
        .schemaVersion = 2,
        .mediaType = .ImageManifest,
        .config = oci.image.Descriptor{
            .mediaType = .ImageConfig,
            .digest = oci.image.Digest{
                .algorithm = .Sha256,
                .value = digest,
            },
            .size = confData.len,
        },
        .layers = self.layers.items,
    };

    const manFile = try resultDir.createFile("manifest.json", .{});
    defer manFile.close();

    try std.json.stringify(manifest, .{
        .emit_null_optional_fields = false,
    }, manFile.writer());
}

fn runInContainer(self: *@This(), stageNum: usize, cmd: []const u8) !void {
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
    } else {
        var status: u32 = 0;
        _ = nix.waitpid(pidt, &status, 0);
        try self.unmountOverlayFs();
        if (status != 0) {
            return error.BuildStepFailed;
        }
        // Success - save the layer
        try self.commitLayer(stageNum);
    }
}

fn commitLayer(self: *@This(), stageNum: usize) !void {
    var layerDir = try std.fs.openDirAbsolute(try self.layerDirPath(stageNum), .{
        .iterate = true,
    });
    defer layerDir.close();

    const resultDir = try std.fs.openDirAbsolute(try self.resultDirPath(), .{});

    try resultDir.makePath("blobs/sha256");

    const blobPath = try std.fmt.allocPrint(self.a, "blobs/temp_{d}.tar", .{stageNum});
    defer self.a.free(blobPath);

    var blobFile = try resultDir.createFile(blobPath, .{});

    var tw = std.tar.writer(blobFile.writer());

    var walker = try layerDir.walk(self.a);
    defer walker.deinit();

    const linkBuf = try self.a.alloc(u8, 1024);
    defer self.a.free(linkBuf);

    while (try walker.next()) |entry| {
        //std.debug.print("adding entry: {s}\n", .{entry.path});
        switch (entry.kind) {
            .directory => try tw.writeDir(entry.path, .{}),
            .file => {
                var file = try entry.dir.openFile(entry.basename, .{});
                defer file.close();

                const stat = try file.stat();

                try tw.writeFileStream(entry.path, stat.size, file.reader(), .{
                    .mode = @intCast(stat.mode),
                });
            },
            .sym_link => {
                const linkName = try entry.dir.readLink(entry.basename, linkBuf);
                try tw.writeLink(entry.path, linkName, .{});
            },
            else => return error.UnsupportedEntryKind,
        }
    }

    try tw.finish();

    // Get hash of the layer
    blobFile.close();

    const blobReader = try resultDir.openFile(blobPath, .{});
    defer blobReader.close();

    std.debug.print("reopened blob file {s}\n", .{blobPath});
    var hash = Sha256.init(.{});

    const readBuf = try self.a.alloc(u8, 4096);
    defer self.a.free(readBuf);

    var size: usize = 0;

    while (true) {
        const read = try blobReader.read(readBuf);
        if (read > 0) {
            hash.update(readBuf[0..read]);
            size += read;
        } else {
            break;
        }
    }

    const digest = try std.fmt.allocPrint(self.a, "{s}", .{
        std.fmt.fmtSliceHexLower(&hash.finalResult()),
    });

    const newBlobPath = try std.fmt.allocPrint(self.a, "blobs/sha256/{s}", .{digest});
    defer self.a.free(newBlobPath);

    try resultDir.rename(blobPath, newBlobPath);

    const descriptor = oci.image.Descriptor{
        .mediaType = .ImageLayer,
        .digest = oci.image.Digest{
            .algorithm = .Sha256,
            .value = digest,
        },
        .size = size,
    };

    try self.layers.append(descriptor);

    std.debug.print("committed: {s}\n", .{digest});
}

fn runProcess(a: std.mem.Allocator, cmd: []const u8) !void {
    var child = std.process.Child.init(&.{
        "/bin/sh",
        "-c",
        cmd,
    }, a);

    var env = std.process.EnvMap.init(a);
    defer env.deinit();

    try env.put("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games");
    try env.put("HOME", "/root");

    child.env_map = &env;

    child.stdout = std.io.getStdOut();
    child.stderr = std.io.getStdErr();

    try child.spawn();

    const result = try child.wait();
    std.process.exit(result.Exited);
}

fn mergedPath(self: @This()) ![:0]u8 {
    return std.fmt.allocPrintZ(
        self.a,
        "/tmp/apport-builds/{s}/merged",
        .{self.id},
    );
}

fn layerDirPath(self: @This(), stageNum: usize) ![]const u8 {
    return std.fmt.allocPrint(
        self.a,
        "/tmp/apport-builds/{s}/upper-{d}",
        .{ self.id, stageNum },
    );
}

fn resultDirPath(self: @This()) ![]const u8 {
    return std.fmt.allocPrint(
        self.a,
        "/tmp/apport-builds/{s}/result",
        .{self.id},
    );
}

fn rootFsPath(self: @This()) ![]const u8 {
    return std.fs.path.join(self.a, &.{
        self.imagePath, "rootfs",
    });
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
    const upper = try self.layerDirPath(stageNum);
    defer self.a.free(upper);
    try std.fs.makeDirAbsolute(upper);

    const work = try std.fmt.allocPrint(
        self.a,
        "/tmp/apport-builds/{s}/work-{d}",
        .{ self.id, stageNum },
    );
    defer self.a.free(work);
    try std.fs.makeDirAbsolute(work);

    var lowerDirs = std.ArrayList([]const u8).init(self.a);

    // Previous upper dirs become part of lower dir list
    if (stageNum > 0) {
        var i: usize = stageNum;
        while (i > 0) : (i -= 1) {
            const prevUpper = try self.layerDirPath(i - 1);

            try lowerDirs.append(prevUpper);
        }
    }

    const rootFs = try self.rootFsPath();
    defer self.a.free(rootFs);

    try lowerDirs.append(rootFs);

    const lowerSlice = try lowerDirs.toOwnedSlice();
    defer self.a.free(lowerSlice);

    const lower = try std.mem.join(self.a, ":", lowerSlice);
    defer self.a.free(lower);

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
