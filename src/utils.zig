const std = @import("std");
const string = []const u8;

fn dirExists(path: string) !bool {
    _ = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => {
            return err;
        },
    };
    return true;
}

pub fn findMdDir(allocator: std.mem.Allocator) !string {
    const cwd = std.fs.cwd();
    const cwd_path = try cwd.realpathAlloc(allocator, "md");
    if (try dirExists(cwd_path)) {
        return cwd_path;
    }
    return error.NoMdDir;
}

pub fn findMdFiles(allocator: std.mem.Allocator, md_dir: string) ![]string {
    const dir = try std.fs.openDirAbsolute(md_dir, .{ .iterate = true });
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var md_files = std.ArrayList(string).init(allocator);

    while (try walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const filename = entry.path;
        const ext = std.fs.path.extension(filename);
        if (std.mem.eql(u8, ext, ".md")) {
            try md_files.append(try std.fs.path.join(allocator, &.{ md_dir, filename }));
        }
    }

    return md_files.toOwnedSlice();
}

pub fn moveAssets(allocator: std.mem.Allocator, md_dir: string) !void {
    const cwd = std.fs.cwd();
    const cwd_path = try cwd.realpathAlloc(allocator, ".");
    const html_dir_path = try std.fs.path.join(allocator, &.{ cwd_path, "html" });

    if (!(try dirExists(html_dir_path))) {
        _ = try cwd.makeDir("html");
    }

    var output_dir = try cwd.openDir("html", .{});
    defer output_dir.close();

    var dir = try std.fs.openDirAbsolute(md_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var assets = std.ArrayList(string).init(allocator);

    while (try walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const filename = entry.path;
        const ext = std.fs.path.extension(filename);
        if (std.mem.eql(u8, ext, ".css") or
            std.mem.eql(u8, ext, ".js") or
            std.mem.eql(u8, ext, ".png") or
            std.mem.eql(u8, ext, ".jpg") or
            std.mem.eql(u8, ext, ".jpeg") or
            std.mem.eql(u8, ext, ".gif"))
        {
            const path = try dir.realpathAlloc(allocator, filename);
            try assets.append(path);
        }
    }

    for (assets.items) |asset| {
        const filename = std.fs.path.basename(asset);
        _ = output_dir.createFile(filename, .{}) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            }
        };
        const filepath = try output_dir.realpathAlloc(allocator, filename);
        try std.fs.copyFileAbsolute(asset, filepath, .{});
    }
}

pub fn writeTag(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    tag: []const u8,
    content: []const u8,
    pending_id: *?string,
) !void {
    try file.writeAll("<");
    try file.writeAll(tag);
    if (pending_id.*) |id_val| {
        try file.writeAll(" id=\"");
        try file.writeAll(id_val);
        try file.writeAll("\"");
        pending_id.* = null;
    }
    try file.writeAll(">");

    const output = try parseInline(allocator, content);
    try file.writeAll(output);

    try file.writeAll("</");
    try file.writeAll(tag);
    try file.writeAll(">\n");
}

pub fn htmlEscape(allocator: std.mem.Allocator, content: string) !string {
    var output = std.ArrayList(u8).init(allocator);

    var it = std.unicode.Utf8Iterator{ .bytes = content, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            '<' => try output.appendSlice("&lt;"),
            '>' => try output.appendSlice("&gt;"),
            '&' => try output.appendSlice("&amp;"),
            '"' => try output.appendSlice("&quot;"),
            '\'' => try output.appendSlice("&apos;"),
            else => {
                // Append the codepoint as UTF-8
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch @panic("utf8 encode failed");
                try output.appendSlice(buf[0..len]);
            },
        }
    }

    return output.toOwnedSlice();
}

fn parseInline(allocator: std.mem.Allocator, line: string) !string {
    var output = std.ArrayList(u8).init(allocator);

    var inBold: ?u8 = null;
    var inItalic: ?u8 = null;
    var inCode = false;

    var idx: usize = 0;
    while (idx < line.len - 1) {
        const current = line[idx];
        const next = line[idx + 1];

        if (current == '\\' and (next == '*' or next == '_' or next == '`')) {
            try output.append(next);
            idx += 2;
            continue;
        }

        if (current == '[') {
            // find closing ']'
            const close_bracket = std.mem.indexOf(u8, line[idx..], "]");
            if (close_bracket) |cb| {
                if (cb + 1 < line.len and line[idx + cb + 1] == '(') {
                    const text = line[idx + 1 .. idx + cb];
                    const close_paren = std.mem.indexOf(u8, line[idx + cb + 1 ..], ")");
                    if (close_paren) |p| {
                        const url = line[idx + cb + 2 .. idx + cb + 1 + p];

                        try output.appendSlice("<a href=\"");
                        try output.appendSlice(url);
                        try output.appendSlice("\"");

                        idx = idx + cb + 1 + p + 1;
                        const blank_check = idx;
                        const blank = blank_check + 9;
                        if (blank < line.len and std.mem.eql(u8, line[blank_check..blank], "{noblank}")) {
                            idx = blank;
                        } else {
                            try output.appendSlice(" target=\"_blank\"");
                        }
                        try output.appendSlice(">");
                        try output.appendSlice(text);
                        try output.appendSlice("</a>");
                        continue;
                    } else {
                        try output.appendSlice("<a href=\"\">");
                        try output.appendSlice(text);
                        try output.appendSlice("</a>");
                        idx = idx + cb + 1;
                        continue;
                    }
                }
            } else {
                try output.appendSlice("[");
                idx += 1;
                continue;
            }
        }
        if (current == '!') {
            // Check if the next character is a link
            if (idx + 1 < line.len and line[idx + 1] == '[') {
                idx += 1;
                const close_bracket = std.mem.indexOf(u8, line[idx..], "]");
                if (close_bracket) |cb| {
                    if (cb + 1 < line.len and line[idx + cb + 1] == '(') {
                        const text = line[idx + 1 .. idx + cb];
                        const close_paren = std.mem.indexOf(u8, line[idx + cb + 1 ..], ")");
                        if (close_paren) |p| {
                            const url = line[idx + cb + 2 .. idx + cb + 1 + p];
                            var url_items = std.mem.splitScalar(u8, url, ' ');
                            var url_idx: usize = 0;
                            var link_text: string = "";
                            var title: string = "";
                            while (url_items.next()) |item| {
                                switch (url_idx) {
                                    0 => {
                                        link_text = item;
                                        url_idx += 1;
                                    },
                                    1 => {
                                        title = std.mem.trim(u8, item, "\"");
                                        break;
                                    },
                                    else => {
                                        break;
                                    },
                                }
                            }

                            try output.appendSlice("<img src=\"");
                            try output.appendSlice(link_text);
                            try output.appendSlice("\"");
                            try output.appendSlice(" alt=\"");
                            try output.appendSlice(text);
                            try output.appendSlice("\"");
                            try output.appendSlice(" title=\"");
                            try output.appendSlice(title);
                            try output.appendSlice("\"");

                            idx = idx + cb + 1 + p + 1;
                            try output.appendSlice("/>");
                            continue;
                        } else {
                            try output.appendSlice("<img src=\"\" alt=\"");
                            try output.appendSlice(text);
                            try output.appendSlice("\"/>");
                            idx = idx + cb + 1;
                            continue;
                        }
                    }
                } else {
                    try output.appendSlice("[");
                    idx += 1;
                    continue;
                }
            } else {
                try output.append(current);
                idx += 1;
                continue;
            }
        }

        if (idx + 1 < line.len and (line[idx] == '*' or line[idx] == '_') and line[idx + 1] == line[idx]) {
            if (inBold == null) {
                inBold = line[idx];
                try output.appendSlice("<strong>");
            } else if (inBold == line[idx]) {
                inBold = null;
                try output.appendSlice("</strong>");
            } else {
                try output.append(line[idx]);
                idx += 1;
                continue;
            }
            idx += 2;
            continue;
        } else if (current == '*' or current == '_') {
            if (inItalic == null) {
                try output.appendSlice("<em>");
                inItalic = current;
                idx += 1;
                continue;
            } else if (inItalic == current) {
                try output.appendSlice("</em>");
                inItalic = null;
                idx += 1;
                continue;
            } else {
                try output.append(line[idx]);
                idx += 1;
                continue;
            }
        } else if (current == '`') {
            if (inCode) {
                try output.appendSlice("</code>");
                inCode = false;
                idx += 1;
                continue;
            } else {
                try output.appendSlice("<code>");
                inCode = true;
                idx += 1;
                continue;
            }
        } else {
            try output.append(line[idx]);
            idx += 1;
        }
    }

    if (idx == line.len - 1 and (line[idx] != '*' and line[idx] != '_' and line[idx] != '`')) {
        try output.append(line[idx]);
    }

    if (inCode) {
        try output.appendSlice("</code>");
    }
    if (inBold != null) {
        try output.appendSlice("</strong>");
    }
    if (inItalic != null) {
        try output.appendSlice("</em>");
    }

    return output.toOwnedSlice();
}

pub fn getIndentLevel(line: string, indent_size: usize) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count / indent_size;
}
