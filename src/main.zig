const std = @import("std");
const image = @import("./image.zig");
const container = @import("./container.zig");
const build = @import("./build/root.zig");
const Provider = @import("images/Provider.zig");

pub fn main() !void {
    const imageDir = try std.fs.cwd().openDir("images", .{});
    //const outputDir = try std.fs.cwd().openDir("rootfs", .{});

    //try image.image2rootfs(std.heap.page_allocator, imageDir, outputDir);

    //try container.runInContainer(std.heap.page_allocator, outputDir);
    const provider = Provider{
        .a = std.heap.page_allocator,
        .dir = imageDir,
    };
    const frozen = try provider.find(.{
        .repo = "ubuntu",
        .tag = "latest",
    });
    std.debug.print("frozen: {s}\n", .{frozen.hash});
}
