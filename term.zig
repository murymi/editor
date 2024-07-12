const std = @import("std");
const inc = @import("inc.zig");
const vec = inc.vec;
const Allocator = inc.Allocator;
pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const println = inc.println;
const print = inc.print;
const os = inc.os;
const ed = @import("editor.zig");

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
        termios.cc[5] = 1;
        termios.cc[6] = 0;
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

const Modifier = struct {
    const Self = @This();
    ctrl: bool = false,
    shift: bool = false,
    super: bool = false,
    alt: bool = false,
};

const _null: u8 = 0;
const ctrlc: u8 = 3;
const ctrld: u8 = 4;
const ctrlf: u8 = 6;
const ctrlh: u8 = 8;
const tab: u8 = 9;
const ctrll: u8 = 12;
const enter: u8 = 13;
const ctrlq: u8 = 17;
const ctrls: u8 = 19;
const ctrlu: u8 = 21;
const esc: u8 = 27;
const backspace: u8 = 127;
const up: u8 = 128;
const down: u8 = 129;
const left: u8 = 130;
const right: u8 = 131;

const KeyEvent = struct { key: u8, modifier: Modifier };

const EventKind = union(enum) {
    keyevent: KeyEvent,
};

const Event = struct {
    kind: EventKind,
};

const MonitorError = error{PollError};

const Monitor = struct {
    ctx: ReadWriter,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    buffer: vec(u8),

    const IOError = error{ ReadError, WriteError };

    const ReadWriter = struct {
        fn read(ctx: *ReadWriter, buf: []u8) anyerror!usize {
            const r = os.read(std.c.STDIN_FILENO, buf[0..].ptr, buf.len);
            switch (os.getErrno(r)) {
                .SUCCESS => return r,
                .INTR => return read(ctx, buf),
                else => return error.ReadError,
            }
        }

        fn write(ctx: *ReadWriter, buf: []const u8) anyerror!usize {
            const r = os.write(os.STDOUT_FILENO, buf.ptr, buf.len);
            switch (os.getErrno(r)) {
                .SUCCESS => return r,
                .INTR => return ReadWriter.write(ctx, buf),
                else => return error.ReadError,
            }
        }
    };

    const Self = @This();
    fn init(alloc: Allocator) Self {
        var m: Self = undefined;
        m.reader = .{ .context = @as(*anyopaque, @ptrFromInt(0xfefe)), .readFn = @as(*const fn (*const anyopaque, []u8) anyerror!usize, @ptrCast(&ReadWriter.read)) };
        m.writer = .{ .context = @as(*anyopaque, @ptrFromInt(0xfefe)), .writeFn = @as(*const fn (*const anyopaque, []const u8) anyerror!usize, @ptrCast(&ReadWriter.write)) };
        m.buffer = vec(u8).init(alloc);
        return m;
    }

    fn clear(self: *Self) !void {
        _ = try self.buffer.appendSlice("\x1b[J");
    }

    fn home(self: *Self) !void {
        _ = try self.buffer.appendSlice("\x1b[H");
    }

    fn goto(self: *Self, pos: ed.Editor.Pos) !void {
        var buf = [1]u8{0} ** 10;
        _ = try self.buffer.appendSlice(try std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ pos.row, pos.col }));
    }

    fn hidecursor(self: *Self) !void {
        _ = try self.buffer.appendSlice("\x1b[?25l");
    }

    fn showcursor(self: *Self) !void {
        _ = try self.buffer.appendSlice("\x1b[?25h");
    }

    fn write(self: *Self, buf: []const u8) !void {
        _ = try self.buffer.appendSlice(buf);
    }

    fn flush(self: *Self) !void {
        _ = try self.writer.write(self.buffer.items);
        self.buffer.clearAndFree();
    }

    fn getWindowSize(_: *Self) ed.Editor.Pos {
        const ws = std.mem.zeroes(os.winsize);
        switch (os.getErrno(os.ioctl(os.STDOUT_FILENO, 0x5413, @intFromPtr(&ws)))) {
            .SUCCESS => {
                if (ws.ws_col == 0) {}
            },
            else => @panic("ioctl failed"),
        }
        return ed.Editor.Pos{ .col = ws.ws_col, .row = ws.ws_row };
    }

    fn refresh(self: *Self) !void {
        _ = self.getWindowSize();
        try self.hidecursor();
        try self.home();
        try self.clear();
        for (editor.rows.items) |row| {
            if (row.characters.items.len > 0) {
                try monitor.write(row.characters.items[0 .. row.characters.items.len - 1]);
                if (row.characters.items[row.characters.items.len - 1] != '\n') {
                    try monitor.write(row.characters.items[row.characters.items.len - 1 ..]);
                }
            }
            try monitor.write("\r\n");
        }
        const pos = ed.Editor.Pos{ .row = editor.cursor_pos.row + 1, .col = editor.cursor_pos.col + 1 };
        try self.goto(pos);
        try self.showcursor();
        try self.flush();
    }

    fn poll(self: *Self) !Event {
        var buf = [1]u8{0} ** 10;
        var n: usize = 0;
        while (n == 0) {
            n = try self.reader.read(buf[0..1]);
        }
        std.debug.assert(n == 1);
        switch (buf[0]) {
            27 => {
                var e = Event{ .kind = EventKind{ .keyevent = KeyEvent{ .key = esc, .modifier = .{} } } };
                if (try self.reader.read(buf[0..1]) == 0) {
                    e.kind.keyevent.key = esc;
                    return e;
                }

                if (try self.reader.read(buf[1..2]) == 0) {
                    e.kind.keyevent.key = esc;
                    return e;
                }

                if (buf[0] == '[') {
                    if (buf[1] >= '0' and buf[1] <= '9') {} else {
                        switch (buf[1]) {
                            'A' => e.kind.keyevent.key = up,
                            'B' => e.kind.keyevent.key = down,
                            'C' => e.kind.keyevent.key = right,
                            'D' => e.kind.keyevent.key = left,
                            else => {},
                        }
                    }
                }
                return e;
            },
            else => |c| {
                return .{ .kind = EventKind{ .keyevent = KeyEvent{ .key = c, .modifier = .{} } } };
            },
        }
    }
};

var monitor: Monitor = undefined;
var editor: ed.Editor = undefined;

export fn sigwinchHandler(_: c_int) void {
    monitor.refresh() catch {};
}

pub fn main() !void {
    const allocator = gpa.allocator();
    var term = try Terminal.init(0);
    try term.raw();
    defer term.cook() catch {};
    editor = ed.Editor.init(allocator);

    monitor = Monitor.init(allocator);
    var act = std.mem.zeroes(os.Sigaction);
    act.handler = .{ .handler = sigwinchHandler };
    _ = os.sigaction(os.SIG.WINCH, &act, null);

    for (0..1000) |_| {
        try monitor.refresh();
        const event = try monitor.poll();
        switch (event.kind) {
            .keyevent => |ke| switch (ke.key) {
                esc => break,
                up => editor.up(),
                down => editor.down(),
                left => editor.back(),
                right => editor.forw(),
                enter => try editor.addchar('\n'),
                backspace => try editor.delchar(),
                else => |c| try editor.addchar(c),
            },
        }
    }

    try monitor.clear();
    try monitor.home();
    try monitor.flush();
}
