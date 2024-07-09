const std = @import("std");
const print = std.debug.print;
const vec = std.ArrayList;
const Allocator = std.mem.Allocator;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const os = std.os.linux;

fn println(comptime fmt: []const u8, args: anytype) void {
    print(fmt, args);
    print("\n", .{});
}

fn setRawMode() void {}

fn unset() void {}

const TermError = error{ TcGetAttr, TcSetAttr };

const Terminal = struct {
    termios: os.termios,
    set: bool,
    fd: os.fd_t,

    const Self = @This();

    fn init(fd: os.fd_t) !Self {
        var s = Self{ .fd = fd, .termios = std.mem.zeroes(os.termios), .set = false };

        if (os.tcgetattr(fd, &s.termios) != 0) {
            return error.TcGetAttr;
        }
        return s;
    }

    fn raw(self: *Self) !void {
        if (std.mem.asBytes(&self.termios) == std.mem.asBytes(&std.mem.zeroes(os.termios))) {
            return error.TcSetAttr;
        }
        var termios: os.termios = self.termios;
        termios.iflag.BRKINT = false;
        termios.iflag.ICRNL = false;
        termios.iflag.INPCK = false;
        termios.iflag.ISTRIP = false;
        termios.iflag.IXON = false;
        termios.oflag.OPOST = false;
        termios.cflag.CSTOPB = true;
        termios.lflag.ECHO = false;
        termios.lflag.ICANON = false;
        termios.lflag.IEXTEN = false;
        termios.lflag.ISIG = false;
        termios.cc[6] = 0;
        termios.cc[5] = 0;
        if (os.tcsetattr(self.fd, os.TCSA.FLUSH, &termios) != 0) {
            return error.TcSetAttr;
        }
        self.set = true;
    }

    fn cook(self: *Self) !void {
        if (!self.set) return;
        if (os.tcsetattr(self.fd, os.TCSA.FLUSH, &self.termios) != 0) {
            return error.TcSetAttr;
        }
    }
};

const MonitorError = error {
    PollError
};

const Monitor = struct {
    fds: vec(os.pollfd),

    const Self = @This();
    fn init(a: Allocator) Self {
        return Self {
            .fds = vec(os.pollfd).init(a)
        };
    }

    fn add(self: *Self, fd: os.fd_t) !void {
        try self.fds.append(.{
            .fd = fd,
            .events = os.POLL.IN,
            .revents = 0
        });
    }

    fn poll(self: *Self, timeout: i32) !void {
        const p = os.poll(self.fds.items.ptr, self.fds.items.len, timeout);
        if(p < 0) return error.PollError;
    }
};

pub fn main() !void {
    var handle = try Terminal.init(0);
    try handle.raw();
    defer handle.cook() catch {};

    const allocator = gpa.allocator();

    var monitor = Monitor.init(allocator);
    try monitor.add(0);

    try monitor.poll(-1);
}
