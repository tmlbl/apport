const std = @import("std");
const RegistryClient = @import("./RegistryClient.zig");

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

/// Base image reference with a precise SHA tag
pub const Frozen = struct {
    ref: VagueReference,
    hash: []const u8,
};

fn getRepoDir(self: @This(), ref: VagueReference) !std.fs.Dir {
    const subPath = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ ref.repo, ref.tag });
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

/// Given a vague reference like ubuntu:latest, find a candidate for
/// a frozen base image
pub fn find(self: @This(), ref: VagueReference) !Frozen {
    var repoDir = try self.getRepoDir(ref);
    defer repoDir.close();

    try self.importLatest(ref);

    return Frozen{
        .ref = ref,
        .hash = "",
    };
}

fn importLatest(self: @This(), ref: VagueReference) !void {
    var repoDir = try self.getRepoDir(ref);
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
}
