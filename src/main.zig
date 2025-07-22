const std = @import("std");
const image = @import("./image.zig");
const container = @import("./container.zig");

pub fn main() !void {
    const imageDir = try std.fs.cwd().openDir("images/ubuntu/latest", .{});
    const outputDir = try std.fs.cwd().openDir("rootfs", .{});

    try image.image2rootfs(std.heap.page_allocator, imageDir, outputDir);

    try container.runInContainer(std.heap.page_allocator, outputDir);
}
