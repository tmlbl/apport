const std = @import("std");
const RegistryClient = @import("./RegistryClient.zig");
const ImageRef = @import("../build/Config.zig").ImageRef;
const rootfs = @import("./rootfs.zig");
const date = @import("../util/date.zig");

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

pub fn getImagePath(self: @This(), ref: ImageRef) ![]const u8 {
    const dir = try self.getRepoDir(ref);
    return dir.realpathAlloc(self.a, ".");
}

fn initRootFS(self: @This(), ref: ImageRef) !void {
    const repoDir = try self.getRepoDir(ref);
    repoDir.makeDir("rootfs") catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        } else {
            // TODO: verify integrity of rootfs
            return;
        }
    };
    const targetDir = try repoDir.openDir("rootfs", .{});
    try rootfs.image2rootfs(self.a, repoDir, targetDir);
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

pub fn importLatest(self: @This(), ref: VagueReference, progressStream: std.io.AnyWriter) !ImageRef {
    const dateTag = try date.dateTagAlloc(self.a);
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
            &.{ "blobs", "sha256", descriptor.digest.value },
        );
        defer self.a.free(blobPath);

        std.log.debug("downloading layer: {s}...", .{blobPath});

        var file = try repoDir.createFile(blobPath, .{});
        defer file.close();

        try self.registryClient.downloadLayer(ref.repo, token, descriptor.digest.value, file, progressStream);
    }

    // Write config.json. We just save this as a file instead of a sha blob
    var configFile = try repoDir.createFile("config.json", .{});
    defer configFile.close();
    try self.registryClient.downloadLayer(
        ref.repo,
        token,
        manifest.config.digest.value,
        configFile.writer(),
        progressStream,
    );

    // Write manifest.json
    var manFile = try repoDir.createFile("manifest.json", .{});
    defer manFile.close();
    try std.json.stringify(manifest, .{
        .emit_null_optional_fields = false,
    }, manFile.writer());

    const imageRef = ImageRef{
        .repo = ref.repo,
        .tag = ref.tag,
        .id = try self.a.dupe(u8, dateTag),
    };
    try self.initRootFS(imageRef);
    return imageRef;
}
