const std = @import("std");
const Io = std.Io;
const log = std.log;

const Monitor = @import("Monitor.zig");

const Tags = @This();
const state = &@import("root").state;

monitor: *Monitor,
list: std.ArrayList(Tag),
click_bounds: std.ArrayList(Bounds),
hovered: ?usize = null,
current: ?usize = null,

pub const Tag = struct {
    name: []u8,
};

pub const Bounds = struct {
    left: u16,
    right: u16,

    pub fn contains(self: Bounds, x: u32) bool {
        return x >= self.left and x < self.right;
    }
};

pub fn create(monitor: *Monitor) !*Tags {
    const self = try state.gpa.create(Tags);

    self.* = .{
        .monitor = monitor,
        .list = .empty,
        .click_bounds = .empty,
        .hovered = null,
        .current = null,
    };

    return self;
}

pub fn destroy(self: *Tags) void {
    self.clearTags();
    self.list.deinit(state.gpa);

    self.click_bounds.deinit(state.gpa);
    state.gpa.destroy(self);
}

fn clearTags(self: *Tags) void {
    for (self.list.items) |tag| {
        state.gpa.free(tag.name);
    }

    self.list.clearRetainingCapacity();
}

pub fn addTag(self: *Tags, name: []const u8, current: bool, index: usize) !void {
    try self.list.append(state.gpa, .{
        .name = try state.gpa.dupe(u8, name),
    });

    if (current) {
        self.current = index;
    }
}

pub fn handleClick(self: *Tags, x: u32) void {
    const count = @min(
        self.list.items.len,
        self.click_bounds.items.len,
    );

    for (self.click_bounds.items[0..count], 0..) |bounds, index| {
        if (bounds.contains(x)) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "click {d}\n",
                .{index + 1},
            ) catch return;

            Io.File.stdout().writeStreamingAll(
                state.io,
                msg,
            ) catch return;
        }
    }
}

pub fn handleMotion(self: *Tags, x: i32, max_width: u32) bool {
    if (x < 0 or @as(u32, @intCast(x)) >= max_width)
        return self.clearHover();

    const ux: u32 = @intCast(x);

    const count = @min(
        self.list.items.len,
        self.click_bounds.items.len,
    );

    for (self.click_bounds.items[0..count], 0..) |bounds, index| {
        if (bounds.contains(ux)) {
            const old_hovered = self.hovered;
            self.hovered = index;
            return old_hovered != index;
        }
    }

    return self.clearHover();
}

pub fn clearHover(self: *Tags) bool {
    const old_hovered = self.hovered;
    self.hovered = null;
    return old_hovered != null;
}

pub fn parse(self: *Tags, tag_line: []const u8) !void {
    self.clearTags();
    self.current = null;

    var it = std.mem.splitScalar(u8, tag_line, ',');
    var index: usize = 0;

    while (it.next()) |raw_tag| {
        if (raw_tag.len == 0) continue;

        var tag_name = raw_tag;
        var is_current = false;

        // Check for active prefix convention
        if (std.mem.startsWith(u8, tag_name, "*")) {
            is_current = true;
            tag_name = tag_name["*".len..]; // Strip the prefix for display
        }

        try self.addTag(
            tag_name,
            is_current,
            index,
        );

        index += 1;
    }
}
