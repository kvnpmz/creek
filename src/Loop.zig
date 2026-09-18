const Tags = @import("Tags.zig");
const std = @import("std");
const log = std.log;
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;
const Io = std.Io;
const fs = std.fs;

const render = @import("render.zig");
const Loop = @This();

const state = &@import("root").state;

sfd: posix.fd_t,

pub fn init() !Loop {
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, linux.SIG.INT);
    linux.sigaddset(&mask, linux.SIG.TERM);
    linux.sigaddset(&mask, linux.SIG.QUIT);

    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const sfd = linux.signalfd(-1, &mask, linux.SFD.NONBLOCK);

    return Loop{ .sfd = @intCast(sfd) };
}

pub fn run(self: *Loop) !void {
    const wayland = &state.wayland;

    var fds = [_]posix.pollfd{
        .{
            .fd = self.sfd,
            .events = posix.POLL.IN,
            .revents = undefined,
        },
        .{
            .fd = wayland.fd,
            .events = posix.POLL.IN,
            .revents = undefined,
        },
        .{
            .fd = posix.STDIN_FILENO,
            .events = posix.POLL.IN,
            .revents = undefined,
        },
    };

    var status_input: std.ArrayList(u8) = .empty;
    defer status_input.deinit(state.gpa);

    while (true) {
        while (true) {
            const ret = wayland.display.dispatchPending();
            _ = wayland.display.flush();
            if (ret == .SUCCESS) break;
        }

        _ = posix.poll(&fds, -1) catch |err| {
            log.err("poll failed: {s}", .{@errorName(err)});
            return;
        };

        for (fds) |fd| {
            if (fd.revents & posix.POLL.HUP != 0 or fd.revents & posix.POLL.ERR != 0) {
                return;
            }
        }

        // signals
        if (fds[0].revents & posix.POLL.IN != 0) {
            return;
        }

        // wayland
        if (fds[1].revents & posix.POLL.IN != 0) {
            const errno = wayland.display.dispatch();
            if (errno != .SUCCESS) return;
        }
        if (fds[1].revents & posix.POLL.OUT != 0) {
            const errno = wayland.display.flush();
            if (errno != .SUCCESS) return;
        }

        // status input
        if (fds[2].revents & posix.POLL.IN != 0) {
            var status_buffer: [1024]u8 = undefined;
            const rc = posix.read(posix.STDIN_FILENO, &status_buffer) catch {
                continue;
            };

            if (rc == 0) continue;

            try status_input.appendSlice(state.gpa, status_buffer[0..rc]);

            const bar_opt = if (state.wayland.river_seat) |seat|
                seat.focusedBar() orelse (if (state.wayland.monitors.items.len > 0) state.wayland.monitors.items[0].confBar() else null)
            else if (state.wayland.monitors.items.len > 0)
                state.wayland.monitors.items[0].confBar()
            else
                null;

            if (bar_opt) |bar| {
                // Process only complete lines; keep partial input for the next read.
                while (std.mem.indexOfScalar(u8, status_input.items, '\n')) |newline| {
                    const line = status_input.items[0..newline];
                    const remaining = status_input.items[newline + 1 ..];

                    if (line.len > 0) {
                        if (std.mem.startsWith(u8, line, "text ")) {
                            const status_str = line["text ".len..];
                            render.renderText(bar, status_str) catch |err| {
                                log.err("renderText failed: {s}", .{@errorName(err)});
                            };
                            bar.text.surface.commit();
                        } else if (std.mem.startsWith(u8, line, "tags ")) {
                            const tag_list_str = line["tags ".len..];
                            bar.monitor.tags.parse(tag_list_str) catch |err| {
                                log.err("Tags parsing failed: {s}", .{@errorName(err)});
                            };
                            render.renderTags(bar) catch |err| {
                                log.err("renderTags failed: {s}", .{@errorName(err)});
                            };
                            bar.tags.surface.commit();
                        }
                    }

                    const remaining_len = remaining.len;
                    std.mem.copyForwards(u8, status_input.items[0..remaining_len], remaining);
                    status_input.shrinkRetainingCapacity(remaining_len);
                }

                bar.background.surface.commit();
            }
        }
    }
}
