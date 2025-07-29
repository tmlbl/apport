const std = @import("std");
const Stage = @import("./Stage.zig");

a: std.mem.Allocator,
stages: std.ArrayList(Stage),

pub fn init(a: std.mem.Allocator) @This() {
    return @This(){
        .a = a,
        .stages = std.ArrayList(Stage).init(a),
    };
}

pub fn deinit(self: @This()) void {
    for (self.stages.items) |stage| {
        for (stage.steps.items) |step| {
            self.a.free(stage.from.repo);
            self.a.free(stage.from.tag);
            self.a.free(step.args);
        }
        stage.steps.deinit();
    }
    self.stages.deinit();
}

pub fn parse(self: *@This(), source: []const u8) !void {
    var stage = Stage{
        .from = .{
            .repo = "",
            .tag = "",
        },
        .steps = std.ArrayList(Stage.Step).init(self.a),
    };

    var lines = std.mem.splitAny(u8, source, "\n");
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, " ")) |ix| {
            const action = try std.ascii.allocLowerString(self.a, line[0..ix]);
            defer self.a.free(action);

            if (std.mem.eql(u8, action, "from")) {
                const image = line[(ix + 1)..];
                if (std.mem.indexOf(u8, image, ":")) |j| {
                    stage.from = Stage.Reference{
                        .repo = try self.a.dupe(u8, image[0..j]),
                        .tag = try self.a.dupe(u8, image[(j + 1)..]),
                    };
                } else {
                    stage.from = Stage.Reference{
                        .repo = try self.a.dupe(u8, image),
                        .tag = "latest",
                    };
                }
            }

            if (std.meta.stringToEnum(Stage.Step.Kind, action)) |kind| {
                const step = Stage.Step{
                    .kind = kind,
                    .args = try self.a.dupe(u8, line[(ix + 1)..]),
                };
                try stage.steps.append(step);
            }
        }
    }

    try self.stages.append(stage);
}

test "single stage" {
    const data =
        \\FROM ubuntu:latest
        \\RUN apt-get update
    ;

    var config = @This().init(std.testing.allocator);
    defer config.deinit();

    try config.parse(data);

    try std.testing.expectEqual(1, config.stages.items.len);

    const stage = config.stages.getLast();
    try std.testing.expectEqualSlices(u8, "ubuntu", stage.from.repo);
    try std.testing.expectEqualSlices(u8, "latest", stage.from.tag);
    try std.testing.expectEqual(1, stage.steps.items.len);
    try std.testing.expect(stage.steps.getLast().kind == .run);
}
