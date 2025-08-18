const std = @import("std");
const ReqReader = std.http.Client.Request.Reader;

pub const Update = struct {
    name: []const u8,
    percent: usize = 0,
    text: []const u8 = "",
    complete: bool = false,
};

pub const UI = struct {
    const Self = @This();

    stream: ReqReader,
    buf: []u8,

    pub fn init(stream: ReqReader, buf: []u8) Self {
        return Self{ .buf = buf, .stream = stream };
    }

    pub fn update(self: Self) !void {
        const stdout = std.io.getStdOut().writer();
        const barWidth = 50;

        while (true) {
            const line = try self.stream.readUntilDelimiter(self.buf, '\n');
            const parsed = std.json.parseFromSlice(
                Update,
                std.heap.page_allocator,
                line,
                .{},
            ) catch |err| {
                std.debug.print("error parsing line: {s} => {}\n", .{ line, err });
                return;
            };
            defer parsed.deinit();

            const upd = parsed.value;

            try stdout.writeByte('\r');

            _ = try stdout.write(upd.name);
            _ = try stdout.write(": [");

            for (0..barWidth) |i| {
                const n = upd.percent / (100 / barWidth);
                if (i < n) {
                    _ = try stdout.write("█");
                } else {
                    try stdout.writeByte(' ');
                }
            }

            try stdout.writeByte(']');

            if (upd.complete) {
                return;
            }
        }
    }
};
