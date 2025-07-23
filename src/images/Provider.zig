const std = @import("std");

a: std.mem.Allocator,
dir: std.fs.Dir,
upstream: []const u8 = "registry.docker.io",
upstreamAuth: []const u8 = "auth.docker.io",

pub const VagueReference = struct {
    repo: []const u8,
    tag: []const u8,
};

/// Base image reference with a precise SHA tag
pub const Frozen = struct {
    ref: VagueReference,
    hash: []const u8,
};

/// Given a vague reference like ubuntu:latest, find a candidate for
/// a frozen base image
pub fn find(self: @This(), ref: VagueReference) !Frozen {
    const subPath = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ ref.repo, ref.tag });
    defer self.a.free(subPath);

    if (self.dir.openDir(subPath, .{})) |_| {
        std.debug.print("dir exists: {s}\n", .{subPath});
        try self.importLatest(ref);
    } else |err| switch (err) {
        error.FileNotFound => {
            try self.dir.makePath(subPath);
        },
        else => {
            return err;
        },
    }
    return Frozen{
        .ref = ref,
        .hash = "",
    };
}

fn importLatest(self: @This(), ref: VagueReference) !void {
    const token = try self.getToken(ref);
    std.debug.print("token: {s}\n", .{token});
}

fn getToken(self: @This(), ref: VagueReference) ![]const u8 {
    var client = std.http.Client{
        .allocator = self.a,
    };
    const buf = try self.a.alloc(u8, 4096);
    defer self.a.free(buf);

    const uriStr = try std.fmt.allocPrint(
        self.a,
        "https://{s}/token?service={s}&scope=repository:library/{s}:pull",
        .{ self.upstreamAuth, self.upstream, ref.repo },
    );
    defer self.a.free(uriStr);

    const uri = try std.Uri.parse(uriStr);
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = buf,
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    const resBuf = try self.a.alloc(u8, 8192);
    defer self.a.free(resBuf);

    const read = try req.readAll(resBuf);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        self.a,
        resBuf[0..read],
        .{},
    );
    defer parsed.deinit();

    if (parsed.value.object.get("token")) |val| {
        return try self.a.dupe(u8, val.string);
    } else {
        return error.TokenMissing;
    }
}
