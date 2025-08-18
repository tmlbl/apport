const std = @import("std");
const zin = @import("zinatra");

const Config = @import("./build/Config.zig");
const Provider = @import("./images/Provider.zig");
const Dockerfile = @import("./build/Dockerfile.zig");
const Container = @import("./build/Container.zig");

const models = @import("./models/root.zig");

var provider: ?Provider = null;

pub fn main() !void {
    provider = Provider.init(
        std.heap.page_allocator,
        "/tmp/apport-rootfs",
    ) catch |err| {
        std.log.err("could not initialize rootfs provider: {}", .{err});
        std.process.exit(1);
    };

    var s = try zin.new(.{
        .allocator = std.heap.page_allocator,
    });
    defer s.deinit();

    try s.post("/config", createConfig);

    try s.listen();
}

// Receive a Dockerfile and respond with Apport build configuration
fn createConfig(ctx: *zin.Context) !void {
    const req = try ctx.parseJson(models.InitRequest);

    var dockerfile = Dockerfile.init(ctx.allocator());
    try dockerfile.parse(req.dockerfileContents);

    if (dockerfile.stages.items.len < 1) {
        return error.EmptyDockerfile;
    }

    var imageRefs = std.ArrayList(Config.ImageRef).init(ctx.allocator());

    const buf = try ctx.allocator().alloc(u8, 8192);

    var resp = ctx.req.respondStreaming(.{
        .send_buffer = buf,
    });

    for (dockerfile.stages.items) |stage| {
        std.log.debug("importing image {s}:{s}...", .{ stage.from.repo, stage.from.tag });
        const imageRef = try provider.?.importLatest(.{
            .repo = stage.from.repo,
            .tag = stage.from.tag,
        }, resp.writer());
        try imageRefs.append(imageRef);
    }

    try resp.endChunked(.{});
}
