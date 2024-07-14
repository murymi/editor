const std = @import("std");
const inc = @import("inc.zig");
const vec = inc.vec;
const Allocator = inc.Allocator;
pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const println = inc.println;
const print = inc.print;
const os = inc.os;
const ed = @import("editor.zig");
const atomic = std.atomic;
const builtin = std.builtin;
const Pos = ed.Editor.Pos;

const TermError = error{ TcGetAttr, TcSetAttr, Winch };

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
    ws: ed.Editor.Pos,

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
    fn init(alloc: Allocator) !Self {
        var m: Self = undefined;
        m.reader = .{ .context = @as(*anyopaque, @ptrFromInt(0xfefe)), .readFn = @as(*const fn (*const anyopaque, []u8) anyerror!usize, @ptrCast(&ReadWriter.read)) };
        m.writer = .{ .context = @as(*anyopaque, @ptrFromInt(0xfefe)), .writeFn = @as(*const fn (*const anyopaque, []const u8) anyerror!usize, @ptrCast(&ReadWriter.write)) };
        m.buffer = vec(u8).init(alloc);
        try m.updateWindowSize();
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

    fn getCursorPos(self: *Self) !ed.Editor.Pos {
        std.debug.assert(try self.writer.write("\x1b[6n") == 4);
        var buf = [1]u8{0} ** 10;
        var r: usize = 0;
        var i: usize = 0;
        while (true) {
            const n = try self.reader.read(buf[i .. i + 1]);
            if (n == 0) continue;
            std.debug.assert(n == 1);
            if (buf[i..][0] == 'R') break;
            r += n;
            i += 1;
        }
        if (buf[0] != 27 or buf[1] != '[') return error.Winch;
        //println("{s}", .{buf});
        //std.time.sleep(std.time.ns_per_s * 5);
        var iter = std.mem.splitAny(u8, buf[2..r], ";");
        return .{ .row = try std.fmt.parseInt(usize, iter.next().?, 10), .col = try std.fmt.parseInt(usize, iter.next().?, 10) };
    }

    fn updateWindowSize(self: *Self) !void {
        const ws = std.mem.zeroes(os.winsize);
        switch (os.getErrno(os.ioctl(os.STDOUT_FILENO, 0x5413, @intFromPtr(&ws)))) {
            .SUCCESS => {
                if (ws.ws_col == 0) {
                    const curpos = try self.getCursorPos();
                    try self.goto(.{ .row = 999, .col = 999 });
                    try self.flush();
                    const p = try self.getCursorPos();
                    try self.goto(curpos);
                    try self.flush();
                    self.ws = p;
                } else {
                    self.ws = ed.Editor.Pos{ .col = ws.ws_col, .row = ws.ws_row };
                }
            },
            else => {
                const curpos = try self.getCursorPos();
                try self.goto(.{ .row = 999, .col = 999 });
                try self.flush();
                const p = try self.getCursorPos();
                try self.goto(curpos);
                try self.flush();
                self.ws = p;
            },
        }
    }

    fn refresh(self: *Self, edi: *ed.Editor) !void {
        //const ws = try self.getWindowSize();
        const pos = ed.Editor.Pos{ .row = edi.cursor_pos.row + 1, .col = edi.cursor_pos.col + 1 };
        try self.hidecursor();
        try self.home();
        try self.clear();
        for (editor.rows.items) |row| {
            const rowsize = row.characters.items.len;
            const ub = @min(if (rowsize > 0) rowsize - 1 else 0, self.ws.col - 1);
            if (ub == self.ws.col - 1) {
                try monitor.write(row.characters.items[0..ub]);
                try monitor.write(">");
            } else {
                try monitor.write(row.characters.items[0..rowsize]);
            }

            try monitor.write("\r\n");
        }
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
    monitor.updateWindowSize() catch {
        os.exit(1);
    };
    monitor.refresh(&editor) catch {
        os.exit(1);
    };
}

pub fn main() !void {
    const cwd = std.fs.cwd();
    const args = std.os.argv;

    if (args.len != 2) {
        println("usage: {s} <file>", .{args[0]});
        os.exit(1);
    }

    var filename:[]const u8 = undefined;
    filename.ptr = @ptrCast(args[1]);
    filename.len = 0;
    while(true) {
        if(args[1][filename.len] == 0) break;
        filename.len += 1;
    }

    const file = if (cwd.openFile(filename, .{ .mode = .read_write })) |f| f else |e| block: {
        switch (e) {
            std.fs.File.OpenError.FileNotFound => break :block try cwd.createFile(filename, .{ .truncate = true }),
            else => {
                println("failed to open file: {s}", .{args[1]});
                os.exit(1);
            },
        }
    };

    const allocator = gpa.allocator();
    var term = try Terminal.init(0);
    try term.raw();
    defer term.cook() catch {};
    editor = ed.Editor.init(allocator);
    try editor.addfile(file, filename);

    monitor = try Monitor.init(allocator);
    var act = std.mem.zeroes(os.Sigaction);
    act.handler = .{ .handler = sigwinchHandler };
    _ = os.sigaction(os.SIG.WINCH, &act, null);

    for (0..1000) |_| {
        try monitor.refresh(&editor);
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
                ctrls => try editor.savefile(),
                tab => {
                    try editor.addstring("  ");
                },
                else => |c| try editor.addchar(c),
            },
        }
    }

    try monitor.clear();
    try monitor.home();
    try monitor.flush();
}
