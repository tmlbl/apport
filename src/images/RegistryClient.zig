const std = @import("std");
const oci = @import("ocispec");

const Progress = @import("../cli/Progress.zig");

a: std.mem.Allocator,
upstream: []const u8 = "registry.docker.io",
upstreamAuth: []const u8 = "auth.docker.io",

pub fn getPullToken(self: @This(), repo: []const u8) ![]const u8 {
    const uriStr = try std.fmt.allocPrint(
        self.a,
        "https://{s}/token?service={s}&scope=repository:library/{s}:pull",
        .{ self.upstreamAuth, self.upstream, repo },
    );
    defer self.a.free(uriStr);

    const parsed = try self.fetchJson(std.json.Value, uriStr, "");
    defer parsed.deinit();

    if (parsed.value.object.get("token")) |token| {
        return try self.a.dupe(u8, token.string);
    } else {
        return error.TokenMissing;
    }
}

pub fn getManifest(self: @This(), token: []const u8, repo: []const u8, tag: []const u8) !oci.image.Manifest {
    // Get manifest
    const uriStr = try std.fmt.allocPrint(
        self.a,
        "https://registry-1.docker.io/v2/library/{s}/manifests/{s}",
        .{ repo, tag },
    );
    defer self.a.free(uriStr);

    const parsedIndex = try self.fetchJson(oci.image.Index, uriStr, token);
    const index = parsedIndex.value;

    for (index.manifests) |descriptor| {
        if (descriptor.platform) |platform| {
            if (platform.architecture == .Amd64) {
                return try self.getManifestSha(repo, token, descriptor.digest.value);
            }
        }
    }

    return error.NoMatchFound;
}

pub fn getManifestSha(self: @This(), repo: []const u8, token: []const u8, sha: []const u8) !oci.image.Manifest {
    const uriStr = try std.fmt.allocPrint(
        self.a,
        "https://registry-1.docker.io/v2/library/{s}/manifests/sha256:{s}",
        .{ repo, sha },
    );
    defer self.a.free(uriStr);

    const parsedManifest = try self.fetchJson(oci.image.Manifest, uriStr, token);
    return parsedManifest.value;
}

fn fetchJson(self: @This(), comptime T: type, uriStr: []const u8, token: []const u8) !std.json.Parsed(T) {
    var client = std.http.Client{
        .allocator = self.a,
    };
    const buf = try self.a.alloc(u8, 4096);
    defer self.a.free(buf);

    var opts = std.http.Client.RequestOptions{
        .server_header_buffer = buf,
    };
    const tokenHeader = try std.fmt.allocPrint(
        self.a,
        "Bearer {s}",
        .{token},
    );
    defer self.a.free(tokenHeader);
    if (token.len > 0) {
        opts.headers.authorization = .{ .override = tokenHeader };
    }

    const uri = try std.Uri.parse(uriStr);
    var req = try client.open(.GET, uri, opts);
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    var clen: u64 = 8192;
    if (req.response.content_length) |cl| {
        clen = cl;
    }

    const resBuf = try self.a.alloc(u8, clen);
    defer self.a.free(resBuf);

    const read = try req.readAll(resBuf);

    return std.json.parseFromSlice(
        T,
        self.a,
        resBuf[0..read],
        .{},
    );
}

pub fn downloadLayer(
    self: @This(),
    repo: []const u8,
    token: []const u8,
    sha: []const u8,
    writer: anytype, // expects a `std.io.Writer`
    progressStream: std.io.AnyWriter,
) !void {
    var client = std.http.Client{
        .allocator = self.a,
    };

    const buf = try self.a.alloc(u8, 4096);
    defer self.a.free(buf);

    const uriStr = try std.fmt.allocPrint(
        self.a,
        "https://registry-1.docker.io/v2/library/{s}/blobs/sha256:{s}",
        .{ repo, sha },
    );
    defer self.a.free(uriStr);

    const tokenHeader = try std.fmt.allocPrint(
        self.a,
        "Bearer {s}",
        .{token},
    );
    defer self.a.free(tokenHeader);

    const opts = std.http.Client.RequestOptions{ .server_header_buffer = buf, .headers = .{
        .authorization = .{ .override = tokenHeader },
    }, .redirect_behavior = .unhandled };

    const uri = try std.Uri.parse(uriStr);
    var req = try client.open(.GET, uri, opts);
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    switch (req.response.status) {
        .found, .temporary_redirect, .permanent_redirect => {
            const location = req.response.location orelse
                return error.MissingRedirectLocation;

            const redirectUri = try std.Uri.parse(location);
            var redirectReq = try client.open(.GET, redirectUri, .{
                .server_header_buffer = buf,
            });
            defer redirectReq.deinit();

            try redirectReq.send();
            try redirectReq.finish();
            try redirectReq.wait();

            if (redirectReq.response.status != .ok)
                return error.BadRedirect;

            var copyProgress = CopyProgress{
                .name = sha[0..15],
                .readBuf = try self.a.alloc(u8, 8192),
                .progressBuf = try self.a.alloc(u8, 8192),
                .totalLength = redirectReq.response.content_length.?,
            };

            while (true) {
                if (try doCopy(&copyProgress, redirectReq.reader(), writer, progressStream) == 0) {
                    break;
                }
            }
        },
        else => {
            const body = try req.reader().readAllAlloc(self.a, 8192);
            defer self.a.free(body);
            std.log.err("error response to blob download: {s}", .{body});
            return error.FailedStatus;
        },
    }
}

/// Copies from reader to writer while providing progress updates
const CopyProgress = struct {
    name: []const u8,
    readBuf: []u8,
    progressBuf: []u8,
    totalLength: u64,
    written: u64 = 0,
};

pub fn doCopy(self: *CopyProgress, reader: anytype, writer: anytype, progressStream: anytype) !usize {
    const read = try reader.read(self.readBuf);
    if (read == 0) {
        const progress = Progress.Update{
            .name = self.name,
            .percent = 100,
            .complete = true,
        };
        try std.json.stringify(progress, .{}, progressStream);
        try progressStream.writeByte('\n');
        std.debug.print("sent final progress update\n", .{});
        return 0;
    }
    try writer.writeAll(self.readBuf[0..read]);
    self.written += read;

    const percent = (self.written * 100 / self.totalLength);

    const progress = Progress.Update{
        .name = self.name,
        .percent = percent,
    };

    try std.json.stringify(progress, .{}, progressStream);
    try progressStream.writeByte('\n');

    return read;
}
