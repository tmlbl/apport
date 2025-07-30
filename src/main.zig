const std = @import("std");
const Config = @import("./build/Config.zig");
const Provider = @import("./images/Provider.zig");
const Dockerfile = @import("./build/Dockerfile.zig");
const Container = @import("./build/Container.zig");

fn parseDockerfile(a: std.mem.Allocator, path: []const u8) !Dockerfile {
    const cwd = std.fs.cwd();
    const dockerfileContents = try cwd.readFileAlloc(
        a,
        path,
        4096,
    );
    defer a.free(dockerfileContents);

    var dockerfile = Dockerfile.init(a);
    try dockerfile.parse(dockerfileContents);
    return dockerfile;
}

/// Initialize a build configuration from a Dockerfile. Import base images if needed.
/// Write a complete configuration file with the results.
pub fn initDockerfile() !std.fs.File {
    var dockerfile = try parseDockerfile(std.heap.page_allocator, "./Dockerfile");
    defer dockerfile.deinit();

    const provider = try Provider.init(
        std.heap.page_allocator,
        "/tmp/apport-rootfs",
    );

    var imageRefs = std.ArrayList(Config.ImageRef).init(std.heap.page_allocator);
    defer imageRefs.deinit();

    for (dockerfile.stages.items) |stage| {
        const imageRef = try provider.importLatest(.{
            .repo = stage.from.repo,
            .tag = stage.from.tag,
        });

        try imageRefs.append(imageRef);

        std.debug.print("frozen: {s}\n", .{imageRef.id});
    }

    const cwd = std.fs.cwd();
    var configFile = try cwd.createFile("apport.zon", .{});
    defer configFile.close();

    const config = Config{
        .images = imageRefs.items,
    };

    try std.zon.stringify.serialize(config, .{}, configFile.writer());

    return cwd.openFile("apport.zon", .{});
}

pub fn main() !void {
    const cwd = std.fs.cwd();

    // Parse the Dockerfile
    var dockerfile = try parseDockerfile(std.heap.page_allocator, "./Dockerfile");
    defer dockerfile.deinit();

    // Read or initialize config file
    var file = cwd.openFile("apport.zon", .{}) catch |err| switch (err) {
        error.FileNotFound => try initDockerfile(),
        else => {
            return err;
        },
    };
    defer file.close();

    const source_raw = try file.readToEndAlloc(std.heap.page_allocator, 8192);
    defer std.heap.page_allocator.free(source_raw);

    const source = try std.mem.concatWithSentinel(std.heap.page_allocator, u8, &.{source_raw}, 0);
    defer std.heap.page_allocator.free(source);

    const config = try std.zon.parse.fromSlice(Config, std.heap.page_allocator, source, null, .{});

    // Execute build stages
    const provider = try Provider.init(
        std.heap.page_allocator,
        "/tmp/apport-rootfs",
    );

    var i: usize = 0;
    while (i < dockerfile.stages.items.len) : (i += 1) {
        std.log.debug("executing stage: {d}", .{i});
        const stage = dockerfile.stages.items[i];
        const imageRef = config.images[i];

        const imagePath = try provider.getImagePath(imageRef);
        defer std.heap.page_allocator.free(imagePath);

        var container = try Container.init(std.heap.page_allocator, stage, imagePath);
        defer container.deinit();

        try container.run();
    }
}
