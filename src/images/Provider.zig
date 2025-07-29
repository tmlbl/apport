const std = @import("std");
const RegistryClient = @import("./RegistryClient.zig");
const ImageRef = @import("../build/Config.zig").ImageRef;
const rootfs = @import("./rootfs.zig");

a: std.mem.Allocator,
dir: std.fs.Dir,
registryClient: RegistryClient,

pub fn init(a: std.mem.Allocator, rootDir: []const u8) !@This() {
    const dir = try std.fs.openDirAbsolute(rootDir, .{});
    return @This(){ .a = a, .dir = dir, .registryClient = RegistryClient{
        .a = a,
    } };
}

pub const VagueReference = struct {
    repo: []const u8,
    tag: []const u8,
};

pub fn getRootFS(self: @This(), ref: ImageRef) ![]u8 {
    const repoDir = try self.getRepoDir(ref);
    repoDir.makeDir("rootfs") catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };
    const targetDir = try repoDir.openDir("rootfs", .{});
    try rootfs.image2rootfs(self.a, repoDir, targetDir);

    return repoDir.realpathAlloc(self.a, "rootfs");
}

fn getRepoDir(self: @This(), ref: ImageRef) !std.fs.Dir {
    const subPath = try std.fmt.allocPrint(self.a, "{s}/{s}/{s}", .{ ref.repo, ref.tag, ref.id });
    defer self.a.free(subPath);

    return self.dir.openDir(subPath, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try self.dir.makePath(subPath);
                return self.getRepoDir(ref);
            },
            else => {
                return err;
            },
        }
    };
}

fn getDateTag(self: @This()) ![]const u8 {
    const time = std.time.timestamp();
    return try std.fmt.allocPrint(self.a, "{d}", .{time});
}

pub fn importLatest(self: @This(), ref: VagueReference) !ImageRef {
    const dateTag = try self.getDateTag();
    defer self.a.free(dateTag);

    var repoDir = try self.getRepoDir(.{
        .repo = ref.repo,
        .tag = ref.tag,
        .id = dateTag,
    });
    try repoDir.makePath("blobs/sha256");

    const token = try self.registryClient.getPullToken(ref.repo);
    const manifest = try self.registryClient.getManifest(token, ref.repo, ref.tag);

    for (manifest.layers) |descriptor| {
        const blobPath = try std.fs.path.join(
            self.a,
            &[_][]const u8{ "blobs", "sha256", descriptor.digest.value },
        );
        defer self.a.free(blobPath);

        std.log.debug("downloading layer: {s}...", .{blobPath});

        var file = try repoDir.createFile(blobPath, .{});
        defer file.close();

        try self.registryClient.downloadLayer(ref.repo, token, descriptor.digest.value, file);
    }

    // Write config.json. We just save this as a file instead of a sha blob
    var configFile = try repoDir.createFile("config.json", .{});
    defer configFile.close();
    try self.registryClient.downloadLayer(
        ref.repo,
        token,
        manifest.config.digest.value,
        configFile.writer(),
    );

    // Write manifest.json
    var manFile = try repoDir.createFile("manifest.json", .{});
    defer manFile.close();
    try std.json.stringify(manifest, .{
        .emit_null_optional_fields = false,
    }, manFile.writer());

    return ImageRef{
        .repo = ref.repo,
        .tag = ref.tag,
        .id = try self.a.dupe(u8, dateTag),
    };
}
