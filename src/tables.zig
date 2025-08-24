const std = @import("std");
const utils = @import("utils.zig");
const string = []const u8;

pub fn splitTableRow(allocator: std.mem.Allocator, line: string) ![]string {
    var cells = std.ArrayList(string).empty;

    var it = std.mem.tokenizeScalar(u8, line, '|');
    while (it.next()) |cell| {
        const trimmed = std.mem.trim(u8, cell, " \t");
        try cells.append(allocator, try utils.htmlEscape(allocator, trimmed));
    }
    return cells.toOwnedSlice(allocator);
}

pub fn isTableLine(line: string) bool {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '|') {
            if (i == 0 or line[i - 1] != '\\') {
                return true;
            }
        }
    }
    return false;
}

pub fn extractCellId(cell: string) struct { content: string, id: ?string } {
    const trimmed = std.mem.trimRight(u8, cell, " \t");
    if (trimmed.len > 3 and trimmed[trimmed.len - 1] == '}' and trimmed[trimmed.len - 2] != '\\') {
        var i = trimmed.len - 2;
        while (i > 0 and trimmed[i] != '{') : (i -= 1) {}
        if (i > 0 and trimmed[i + 1] == '#') {
            return .{
                .content = std.mem.trimRight(u8, trimmed[0 .. i - 1], " \t"),
                .id = trimmed[i + 2 .. trimmed.len - 1],
            };
        }
    }
    return .{ .content = trimmed, .id = null };
}

pub fn isTableSeparator(line: string) bool {
    for (line) |c| {
        if (c != '|' and c != '-' and c != ':' and c != ' ') {
            return false;
        }
    }
    return true;
}
