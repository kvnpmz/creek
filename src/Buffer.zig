const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;

const pixman = @import("pixman");
const wl = @import("wayland").client.wl;

const Buffer = @This();

const state = &@import("root").state;

mmap: ?Io.File.MemoryMap = null,
data: ?[]u32 = null,
buffer: ?*wl.Buffer = null,
pix: ?*pixman.Image = null,

busy: bool = false,
width: u31 = 0,
height: u31 = 0,
size: u31 = 0,

pub fn resize(self: *Buffer, shm: *wl.Shm, width: u31, height: u31) !void {
    if (width == 0 or height == 0) return;

    self.busy = true;
    self.width = width;
    self.height = height;

    // There doesn't seem to be a way to memfd through a File abstraction, as of Zig 0.16
    const fd = try posix.memfd_create("creek-shm", linux.MFD.CLOEXEC);
    const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(state.io);

    const stride = width * 4;
    self.size = stride * height;
    try file.setLength(state.io, self.size);

    self.mmap = try file.createMemoryMap(state.io, .{ .len = self.size });
    self.data = mem.bytesAsSlice(u32, self.mmap.?.memory);

    const pool = try shm.createPool(fd, self.size);
    defer pool.destroy();

    self.buffer = try pool.createBuffer(0, width, height, stride, .argb8888);
    errdefer self.buffer.?.destroy();
    self.buffer.?.setListener(*Buffer, listener, self);

    self.pix = pixman.Image.createBitsNoClear(.a8r8g8b8, width, height, self.data.?.ptr, stride);
}

pub fn deinit(self: *Buffer) void {
    if (self.pix) |pix| _ = pix.unref();
    if (self.buffer) |buf| buf.destroy();
    if (self.mmap) |*mmap| mmap.destroy(state.io);
}

fn listener(_: *wl.Buffer, event: wl.Buffer.Event, buffer: *Buffer) void {
    switch (event) {
        .release => buffer.busy = false,
    }
}

pub fn nextBuffer(pool: *[2]Buffer, shm: *wl.Shm, width: u16, height: u16) !*Buffer {
    if (pool[0].busy and pool[1].busy) {
        return error.NoAvailableBuffers;
    }
    const buffer = if (!pool[0].busy) &pool[0] else &pool[1];

    if (buffer.width != width or buffer.height != height) {
        buffer.deinit();
        try buffer.resize(shm, width, height);
    }
    return buffer;
}
