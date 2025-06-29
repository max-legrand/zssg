const std = @import("std");
const zssg = @import("zssg");
const zlog = @import("zlog");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try zlog.initGlobalLogger(.INFO, true, null, null, null, allocator);
    defer zlog.deinitGlobalLogger();
}
