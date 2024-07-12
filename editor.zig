const std = @import("std");
const inc = @import("inc.zig");
const vec = inc.vec;
const Allocator = inc.Allocator;
const gpa = inc.gpa;
const println = inc.println;


pub const Editor = struct {
    rows: vec(Row),
    cursor_pos: Pos,
    allocator: Allocator,
    filename: []const u8,

    pub const Pos = struct {
        row: usize,
        col: usize
    };

    const Row = struct {
        index: usize,
        characters: vec(u8),

        fn init(alloc: Allocator) @This() {
            return @This() {
                .index = 0,
                .characters = vec(u8).init(alloc)
            };
        }

        fn deinit(self: *@This()) void {
            self.characters.deinit();
        }
    };

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self {
            .rows = vec(Row).init(allocator),
            .cursor_pos = .{ .col = 0, .row = 0 },
            .allocator = allocator,
            .filename = ""
        };
    }

    pub fn addchar(self: *Self, char: u8) !void {
        const row = if(self.cursor_pos.row > self.rows.items.len or self.rows.items.len == 0) block: {
            try self.rows.appendNTimes(Row.init(self.allocator), (self.cursor_pos.row - self.rows.items.len) + 1);
            break: block &self.rows.items[self.cursor_pos.row];
        } else &self.rows.items[self.cursor_pos.row];

        //if(self.cursor_pos.col >= row.characters.items.len or row.characters.items.len == 0) {
        //    try row.characters.appendNTimes('z', (self.cursor_pos.col - row.characters.items.len) + 1);
        //}

        switch (char) {
            '\n' => {
                var upper = Row.init(self.allocator);
                var lower = Row.init(self.allocator);
                try upper.characters.appendSlice(row.characters.items[0..self.cursor_pos.col]);
                try upper.characters.append('\n');
                try lower.characters.appendSlice(row.characters.items[self.cursor_pos.col..]);
                row.deinit();
                self.rows.items[self.cursor_pos.row] = upper;
                try self.rows.insert(self.cursor_pos.row + 1, lower);
                self.cursor_pos.row += 1;
                self.cursor_pos.col = 0;
            },
            else => {
                try row.characters.insert(self.cursor_pos.col, char);
                self.forw();
            }
        }
    }

    pub fn delchar(self: *Self) !void {
        if(self.cursor_pos.row == 0 and self.cursor_pos.col == 0) return;
        if(self.cursor_pos.col == 0) {
            const cp = self.rows.items[self.cursor_pos.row - 1].characters.items.len - 1;
            _ = self.rows.items[self.cursor_pos.row - 1].characters.pop();
            try self.rows.items[self.cursor_pos.row - 1].characters.appendSlice(
                self.rows.items[self.cursor_pos.row].characters.items[
                    0..
                ]
            );
            var r = self.rows.orderedRemove(self.cursor_pos.row);
            r.deinit();
            self.cursor_pos.row -= 1;
            self.cursor_pos.col = cp;
        } else {
            _ = self.rows.items[self.cursor_pos.row].characters.orderedRemove(self.cursor_pos.col - 1);
            self.cursor_pos.col -= 1;
        }
    }

    pub fn addstring(self: *Self, string: []const u8) !void {
        for(string) |c| {
            try self.addchar(c);
        }
    }

    pub fn addfile(self: *Self, fname: []const u8) !void {
        var file = std.fs.openFileAbsolute(fname, .{ .mode = .read_only }) catch |e| {
            switch (e) {
                std.fs.File.OpenError.FileNotFound => {
                    const f = try std.fs.createFileAbsolute(fname, .{});
                    f.close();
                    return;
                },
                else => return e
            }
        };
        const buf = try file.readToEndAlloc(self.allocator, std.math.maxInt(u16));
        for(buf)|c| {
            try self.addchar(c);
        }
        self.filename = fname;
        defer file.close();
    }

    pub fn savefile(self: *Self) !void {
        if(self.filename.len != 0) {
            var file = try std.fs.createFileAbsolute(self.filename, .{.truncate = true });
            try file.writeAll((try self.tostring()).items);
            file.close();
        }
    }

    pub fn  tostring(self: *Self) !vec(u8) {
        var s = vec(u8).init(self.allocator);
        for(self.rows.items)|row| {
            try s.appendSlice(row.characters.items);
            try s.append('\n');
        }
        if(s.items.len > 0) {
            //std.debug.assert(s.pop() == 0);
        }
        return s;
    }

    pub fn deinit(self: *Self) void {
        for(self.rows.items) |*r| {
            r.deinit();
        }
        self.rows.deinit();
    }

    pub fn forw(self: *Self) void {
        if(self.rows.items.len > 0 and self.rows.items[self.cursor_pos.row].characters.items.len > self.cursor_pos.col) {
            self.cursor_pos.col += 1;
        }
    }

    pub fn back(self: *Self) void {
        if(self.cursor_pos.col > 0) 
            self.cursor_pos.col -= 1;
    }

    pub fn up(self: *Self) void {
        if(self.cursor_pos.row > 0) {
            self.cursor_pos.row -= 1;
            if(self.cursor_pos.col >= self.rows.items[self.cursor_pos.row].characters.items.len) {
                self.cursor_pos.col = self.rows.items[self.cursor_pos.row].characters.items.len - 1;
            }
        }
    }

    pub fn down(self: *Self) void {
        if(self.rows.items.len > self.cursor_pos.row + 1) {
            self.cursor_pos.row += 1;
            if(self.cursor_pos.col >= self.rows.items[self.cursor_pos.row].characters.items.len) {
                self.cursor_pos.col = if(self.rows.items[self.cursor_pos.row].characters.items.len > 0)
                    self.rows.items[self.cursor_pos.row].characters.items.len else 0;
            }
        }

    }
};

test "editor" {
    const testing = std.testing;
    const testalloc = testing.allocator_instance.allocator();
    var editor = Editor.init(testalloc);
    defer editor.deinit();
    try editor.addchar('a');
    try editor.addchar('b');
    try editor.addchar('c');
    try editor.addchar('d');
    try editor.addchar('e');
    try testing.expectEqual(editor.cursor_pos.col, 5);
    const s1 = try editor.tostring();
    defer s1.deinit();
    try testing.expectEqualSlices(u8, "abcde", s1.items[0..editor.cursor_pos.col]);
    try editor.delchar();
    try testing.expectEqualSlices(u8, "abcd", s1.items[0..editor.cursor_pos.col]);
    try editor.delchar();
    try testing.expectEqualSlices(u8, "abc", s1.items[0..editor.cursor_pos.col]);
    try editor.delchar();
    try testing.expectEqualSlices(u8, "ab", s1.items[0..editor.cursor_pos.col]);
    try editor.delchar();
    try testing.expectEqualSlices(u8, "a", s1.items[0..editor.cursor_pos.col]);
    try editor.delchar();
    try testing.expectEqualSlices(u8, "", s1.items[0..editor.cursor_pos.col]);
    try editor.addchar('\n');
    try editor.addchar('\n');
    try editor.addchar('\n');
    try editor.addchar('\n');
    try editor.addchar('\n');
    try editor.addchar('\n');
    try editor.addchar('\n');
    try testing.expectEqual(editor.cursor_pos, Editor.Pos{.col = 0, .row = 7});
    try editor.delchar();
    try editor.delchar();
    try editor.delchar();
    try editor.delchar();
    try editor.delchar();
    try editor.delchar();
    try editor.delchar();
    try testing.expectEqual(editor.cursor_pos, Editor.Pos{.col = 0, .row = 0});
    try editor.addstring("hello\nworld");
    try testing.expectEqual(editor.cursor_pos, Editor.Pos{.col = 5, .row = 1});
    for(0..5)|_| {
        try editor.delchar();
    }
    try testing.expectEqual(editor.cursor_pos, Editor.Pos{.col = 0, .row = 1});
    try editor.delchar();
    try testing.expectEqual(editor.cursor_pos, Editor.Pos{.col = 5, .row = 0});
}