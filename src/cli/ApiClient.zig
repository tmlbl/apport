const std = @import("std");
const InitRequest = @import("../models/InitRequest.zig");
const Config = @import("../build/Config.zig");

const ApiClient = @This();

a: std.mem.Allocator,
apportHost: []const u8 = "http://localhost:3737",

pub fn initProject(self: ApiClient, payload: InitRequest) !std.json.Parsed(Config) {
    var uri = try std.Uri.parse(self.apportHost);

    uri.path.percent_encoded = "/config";
    var client = std.http.Client{
        .allocator = self.a,
    };
    defer client.deinit();

    const buf = try self.a.alloc(u8, 4096);
    defer self.a.free(buf);

    const body = try std.json.stringifyAlloc(self.a, payload, .{});
    defer self.a.free(body);

    var req = try client.open(.POST, uri, .{
        .server_header_buffer = buf,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };

    try req.send();

    try req.writer().writeAll(body);

    try req.finish();
    try req.wait();

    switch (req.response.status) {
        .ok => {
            const read = try req.readAll(buf);
            return std.json.parseFromSlice(Config, self.a, buf[0..read], .{});
        },
        else => {
            std.debug.print("error response: {}\n", .{req.response.status});
            return error.ErrorResponse;
        },
    }
}
