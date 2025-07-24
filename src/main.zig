const std = @import("std");
const image = @import("./image.zig");
const container = @import("./container.zig");
const build = @import("./build/root.zig");
const Provider = @import("./images/Provider.zig");

pub fn main() !void {
    //    const imageDir = try std.fs.cwd().openDir("images", .{});
    //const outputDir = try std.fs.cwd().openDir("rootfs", .{});

    //try image.image2rootfs(std.heap.page_allocator, imageDir, outputDir);

    //try container.runInContainer(std.heap.page_allocator, outputDir);
    const provider = try Provider.init(
        std.heap.page_allocator,
        "/tmp/apport-rootfs",
    );

    const frozen = try provider.find(.{
        .repo = "ubuntu",
        .tag = "latest",
    });

    std.debug.print("frozen at: {s}\n", .{frozen.hash});
}
