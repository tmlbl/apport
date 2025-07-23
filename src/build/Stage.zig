const std = @import("std");

from: []const u8,
steps: std.ArrayList(Step),

pub const Step = struct {
    kind: Kind,
    args: []const u8,

    pub const Kind = enum {
        run,
        add,
    };
};
