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
            const dest_path = try std.fs.path.join(allocator, &.{ cwd_path, "html", filename });
            if (std.fs.path.dirname(dest_path)) |dest_dir| {
                cwd.makePath(dest_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            }

            const src_path = try dir.realpathAlloc(allocator, filename);

            _ = std.fs.createFileAbsolute(dest_path, .{}) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                }
            };
            try std.fs.copyFileAbsolute(src_path, dest_path, .{});
        }
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

fn parseInline(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).init(allocator);

    var inBold: ?u8 = null;
    var inItalic: ?u8 = null;
    var inCode = false;

    var idx: usize = 0;
    while (idx < line.len) {
        const current = line[idx];

        // Escaped formatting characters
        if (current == '\\' and idx + 1 < line.len and
            (line[idx + 1] == '*' or line[idx + 1] == '_' or line[idx + 1] == '`'))
        {
            try output.append(line[idx + 1]);
            idx += 2;
            continue;
        }

        // Inline image: ![alt](url "title"){#id}
        if (current == '!' and idx + 1 < line.len and line[idx + 1] == '[') {
            idx += 1;
            const close_bracket = std.mem.indexOf(u8, line[idx..], "]");
            if (close_bracket) |cb| {
                const after_bracket = idx + cb + 1;
                if (after_bracket < line.len and line[after_bracket] == '(') {
                    const close_paren = std.mem.indexOf(u8, line[after_bracket..], ")");
                    if (close_paren) |p| {
                        const alt = line[idx + 1 .. idx + cb];
                        const url_and_title = line[after_bracket + 1 .. after_bracket + p];

                        // Split url and optional title
                        var url: []const u8 = url_and_title;
                        var title: []const u8 = "";
                        if (std.mem.indexOf(u8, url_and_title, "\"")) |quote_idx| {
                            url = std.mem.trimRight(u8, url_and_title[0..quote_idx], " ");
                            title = std.mem.trim(u8, url_and_title[quote_idx..], "\" ");
                        }

                        idx = after_bracket + p + 1;

                        var id: ?[]const u8 = null;
                        while (true) {
                            while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) : (idx += 1) {}
                            if (idx < line.len and line[idx] == '{') {
                                const close_brace = std.mem.indexOf(u8, line[idx..], "}");
                                if (close_brace) |brace| {
                                    const block = line[idx + 1 .. idx + brace];
                                    if (block.len > 1 and block[0] == '#') {
                                        id = block[1..];
                                    }
                                    idx = idx + brace + 1;
                                    continue;
                                }
                            }
                            break;
                        }

                        try output.appendSlice("<img src=\"");
                        try output.appendSlice(url);
                        try output.appendSlice("\" alt=\"");
                        try output.appendSlice(alt);
                        try output.appendSlice("\"");
                        if (title.len > 0) {
                            try output.appendSlice(" title=\"");
                            try output.appendSlice(title);
                            try output.appendSlice("\"");
                        }
                        if (id) |id_val| {
                            try output.appendSlice(" id=\"");
                            try output.appendSlice(id_val);
                            try output.appendSlice("\"");
                        }
                        try output.appendSlice("/>");
                        continue;
                    }
                }
            }
            // If not a valid image, just output the '!' and continue
            try output.append('!');
            continue;
        }

        // Inline link: [text](url){noblank}{#id}
        if (current == '[') {
            const close_bracket = std.mem.indexOf(u8, line[idx..], "]");
            if (close_bracket) |cb| {
                const after_bracket = idx + cb + 1;
                if (after_bracket < line.len and line[after_bracket] == '(') {
                    const close_paren = std.mem.indexOf(u8, line[after_bracket..], ")");
                    if (close_paren) |p| {
                        const text = line[idx + 1 .. idx + cb];
                        const url = line[after_bracket + 1 .. after_bracket + p];

                        idx = after_bracket + p + 1;

                        var no_blank = false;
                        var id: ?[]const u8 = null;
                        while (true) {
                            while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) : (idx += 1) {}
                            if (idx < line.len and line[idx] == '{') {
                                const close_brace = std.mem.indexOf(u8, line[idx..], "}");
                                if (close_brace) |brace| {
                                    const block = line[idx + 1 .. idx + brace];
                                    if (std.mem.eql(u8, block, "noblank")) {
                                        no_blank = true;
                                    } else if (block.len > 1 and block[0] == '#') {
                                        id = block[1..];
                                    }
                                    idx = idx + brace + 1;
                                    continue;
                                }
                            }
                            break;
                        }
                        // --- END ---

                        try output.appendSlice("<a href=\"");
                        try output.appendSlice(url);
                        try output.appendSlice("\"");
                        if (id) |id_val| {
                            try output.appendSlice(" id=\"");
                            try output.appendSlice(id_val);
                            try output.appendSlice("\"");
                        }
                        if (!no_blank) {
                            try output.appendSlice(" target=\"_blank\"");
                        }
                        try output.appendSlice(">");
                        try output.appendSlice(text);
                        try output.appendSlice("</a>");
                        continue;
                    }
                }
            }
            // If not a valid link, just output the '[' and continue
            try output.append('[');
            idx += 1;
            continue;
        }

        // Bold (** or __)
        if (idx + 1 < line.len and (line[idx] == '*' or line[idx] == '_') and line[idx + 1] == line[idx]) {
            if (inBold == null) {
                inBold = line[idx];
                try output.appendSlice("<strong>");
            } else if (inBold == line[idx]) {
                inBold = null;
                try output.appendSlice("</strong>");
            } else {
                try output.append(line[idx]);
            }
            idx += 2;
            continue;
        }

        // Italic (* or _)
        if (current == '*' or current == '_') {
            if (inItalic == null) {
                inItalic = current;
                try output.appendSlice("<em>");
            } else if (inItalic == current) {
                inItalic = null;
                try output.appendSlice("</em>");
            } else {
                try output.append(current);
            }
            idx += 1;
            continue;
        }

        // Inline code
        if (current == '`') {
            if (inCode) {
                try output.appendSlice("</code>");
                inCode = false;
            } else {
                try output.appendSlice("<code>");
                inCode = true;
            }
            idx += 1;
            continue;
        }

        try output.append(current);
        idx += 1;
    }

    // Close any open tags
    if (inCode) try output.appendSlice("</code>");
    if (inBold != null) try output.appendSlice("</strong>");
    if (inItalic != null) try output.appendSlice("</em>");

    return output.toOwnedSlice();
}

pub fn getIndentLevel(line: string, indent_size: usize) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count / indent_size;
}
