pub const std = @import("std");
pub const print = std.debug.print;
pub const vec = std.ArrayList;
pub const Allocator = std.mem.Allocator;
pub const os = std.os.linux;

pub fn println (comptime fmt: []const u8, args: anytype) void {
    print(fmt, args);
    print("\n", .{});
}