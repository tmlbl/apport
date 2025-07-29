const std = @import("std");

pub const Reference = struct {
    repo: []const u8,
    tag: []const u8,
};

from: Reference,
steps: std.ArrayList(Step),

pub const Step = struct {
    kind: Kind,
    args: []const u8,

    pub const Kind = enum {
        run,
        add,
    };
};
