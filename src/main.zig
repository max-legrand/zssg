const std = @import("std");
const zssg = @import("zssg");
const zlog = @import("zlog");

const major = 0;
const minor = 0;
const patch = 1;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try zlog.initGlobalLogger(.INFO, true, null, null, null, allocator);

    zlog.info("ZSSG v{d}.{d}.{d}", .{ major, minor, patch });

    const dir = try zssg.findMdDir(allocator);
    zlog.info("Found md dir: {s}", .{dir});

    try zssg.moveAssets(allocator, dir);

    const md_files = try zssg.findMdFiles(allocator, dir);
    try zssg.processFiles(allocator, md_files);
}
