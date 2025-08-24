const std = @import("std");
const string = []const u8;
const utils = @import("utils.zig");
const tables = @import("tables.zig");
const zlog = @import("zlog");

pub const findMdDir = utils.findMdDir;
pub const findMdFiles = utils.findMdFiles;
pub const moveAssets = utils.moveAssets;
const writeTag = utils.writeTag;

fn processFileThreadMain(md_file: string) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try processFile(allocator, md_file);
}

pub fn processFiles(allocator: std.mem.Allocator, md_files: []string) !void {
    // Process the files in parallel.
    var threads = std.ArrayList(std.Thread).empty;
    defer threads.deinit(allocator);

    for (md_files) |md_file| {
        zlog.info("Processing file: {s}", .{md_file});
        const thread = try std.Thread.spawn(.{}, processFileThreadMain, .{md_file});
        try threads.append(allocator, thread);

        if (threads.items.len == 4) {
            for (threads.items) |t| {
                t.join();
            }
            threads.clearRetainingCapacity();
        }
    }

    for (threads.items) |thread| {
        thread.join();
    }
}

const Asset = struct {
    path: string,
    save_inline: bool = false,
};

const Frontmatter = struct {
    title: ?string,
    stylesheets: ?std.ArrayList(Asset) = null,
    scripts: ?std.ArrayList(Asset) = null,
};

fn writeBase(allocator: std.mem.Allocator, file: *std.fs.File, frontmatter: Frontmatter) !void {
    try file.writeAll("<!DOCTYPE html>\n");
    try file.writeAll("<html>\n");
    try file.writeAll("<head>\n<meta charset=\"UTF-8\">\n");
    if (frontmatter.title) |title| {
        var empty_string: ?string = null;
        try writeTag(allocator, file.*, "title", title, &empty_string);
    }
    if (frontmatter.stylesheets) |stylesheets| {
        for (stylesheets.items) |stylesheet| {
            if (stylesheet.save_inline) {
                const asset_file = try std.fs.openFileAbsolute(stylesheet.path, .{});
                defer asset_file.close();
                const contents = asset_file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return;
                defer allocator.free(contents);
                try file.writeAll("<style>\n");
                try file.writeAll(contents);
                try file.writeAll("\n</style>\n");
            } else {
                try file.writeAll("<link rel=\"stylesheet\" href=\"");
                try file.writeAll(stylesheet.path);
                try file.writeAll("\">\n");
            }
        }
    }
    if (frontmatter.scripts) |scripts| {
        for (scripts.items) |script| {
            if (script.save_inline) {
                const asset_file = try std.fs.openFileAbsolute(script.path, .{});
                defer asset_file.close();
                const contents = asset_file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return;
                defer allocator.free(contents);
                try file.writeAll("<script>\n");
                try file.writeAll(contents);
                try file.writeAll("\n</script>\n");
            } else {
                try file.writeAll("<script src=\"");
                try file.writeAll(script.path);
                try file.writeAll("\"></script>\n");
            }
        }
    }

    try file.writeAll("</head>\n<body>\n");
}

const footer =
    \\</body>
    \\</html>
;

const ListType = enum { ul, ol };

fn isIdLine(line: string) bool {
    return line.len > 3 and line[0] == '{' and line[1] == '#' and line[line.len - 1] == '}';
}

fn extractId(line: string) string {
    return line[2 .. line.len - 1];
}

fn extractTagName(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '<' or line[1] == '/') return null;
    var i: usize = 1;
    while (i < line.len and std.ascii.isAlphabetic(line[i])) : (i += 1) {}
    if (i > 1) return line[1..i];
    return null;
}

fn processFile(allocator: std.mem.Allocator, md_file: string) !void {
    var md_dir = try std.fs.cwd().openDir("md", .{});
    defer md_dir.close();
    const md_dir_path = try md_dir.realpathAlloc(allocator, ".");

    const rel_path = try std.fs.path.relative(allocator, md_dir_path, md_file);
    const ext = std.fs.path.extension(rel_path);
    const rel_path_without_ext = rel_path[0 .. rel_path.len - ext.len];

    const out_dir_path = std.fs.path.dirname(rel_path_without_ext) orelse "";
    const out_dir_full = try std.fs.path.join(allocator, &.{ "html", out_dir_path });

    std.fs.cwd().makeDir(out_dir_full) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };

    var html_dir = try std.fs.cwd().openDir(out_dir_full, .{});
    defer html_dir.close();

    const base_name = std.fs.path.basename(rel_path_without_ext);
    const html_filename = try std.fmt.allocPrint(allocator, "{s}.html", .{base_name});

    var new_file = try html_dir.createFile(html_filename, .{ .truncate = true });
    defer new_file.close();

    const file = try std.fs.openFileAbsolute(md_file, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var inCodeBlock = false;
    var inBlockQuote: bool = false;

    var list_stack = std.ArrayList(struct { list_type: ListType, indent: usize }).empty;

    var line_idx: usize = 0;

    var pending_id: ?string = null;

    var in_html_block = false;
    var html_tag: ?[]const u8 = null;

    var paragraph_buffer = std.ArrayList(string).empty;
    while (lines.next()) |line| {
        const indent = utils.getIndentLevel(line, 2);
        var trimmed = std.mem.trim(u8, line, " \t");

        if (isIdLine(trimmed)) {
            pending_id = extractId(trimmed);
            continue;
        }

        if (in_html_block) {
            try new_file.writeAll(line);
            try new_file.writeAll("\n");
            if (html_tag) |tag| {
                // Check for closing tag, e.g. </div>
                const close_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
                defer allocator.free(close_tag);
                if (std.mem.indexOf(u8, trimmed, close_tag) != null) {
                    in_html_block = false;
                    html_tag = null;
                }
            }
            continue;
        }

        if (trimmed.len > 0 and trimmed[0] == '<') {
            if (extractTagName(trimmed)) |tag| {
                const close_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
                defer allocator.free(close_tag);
                if (std.mem.indexOf(u8, trimmed, close_tag) != null) {
                    // Opening and closing tag on the same line: just write it, don't enter passthrough
                    try new_file.writeAll(line);
                    try new_file.writeAll("\n");
                    continue;
                } else if (!std.mem.endsWith(u8, trimmed, "/>")) {
                    in_html_block = true;
                    html_tag = tag;
                    try new_file.writeAll(line);
                    try new_file.writeAll("\n");
                    continue;
                }
            }

            try new_file.writeAll(line);
            try new_file.writeAll("\n");
            continue;
        }

        // Start of HTML block
        if (trimmed.len > 0 and trimmed[0] == '<') {
            in_html_block = true;
            try new_file.writeAll(line);
            try new_file.writeAll("\n");
            continue;
        }

        if (std.mem.eql(u8, trimmed, "---") and line_idx == 0) {
            var frontmatter = Frontmatter{
                .title = null,
                .stylesheets = std.ArrayList(Asset).empty,
                .scripts = std.ArrayList(Asset).empty,
            };
            while (lines.peek()) |next_line| {
                _ = lines.next();
                if (std.mem.eql(u8, next_line, "---")) {
                    break;
                } else {
                    if (std.mem.startsWith(u8, next_line, "title: ")) {
                        var title = next_line[7..next_line.len];
                        // If the line starts and ends with quotes, remove them
                        if (title[0] == '"' and title[title.len - 1] == '"') {
                            title = title[1 .. title.len - 1];
                        } else if (title[0] == '\'' and title[title.len - 1] == '\'') {
                            title = title[1 .. title.len - 1];
                        }
                        frontmatter.title = try utils.htmlEscape(allocator, title);
                    } else if (std.mem.startsWith(u8, next_line, "stylesheet: ")) {
                        var stylesheet = next_line[12..next_line.len];
                        var save_inline = false;
                        if (std.mem.endsWith(u8, stylesheet, " - inline")) {
                            save_inline = true;
                            stylesheet = stylesheet[0 .. stylesheet.len - " - inline".len];
                            stylesheet = std.mem.trimRight(u8, stylesheet, " \t");
                        }
                        if (stylesheet[0] == '"' and stylesheet[stylesheet.len - 1] == '"') {
                            stylesheet = stylesheet[1 .. stylesheet.len - 1];
                        } else if (stylesheet[0] == '\'' and stylesheet[stylesheet.len - 1] == '\'') {
                            stylesheet = stylesheet[1 .. stylesheet.len - 1];
                        }

                        if (!save_inline and !(std.mem.startsWith(u8, stylesheet, "http://") or std.mem.startsWith(u8, stylesheet, "https://"))) {
                            stylesheet = try std.fmt.allocPrint(allocator, "/{s}", .{stylesheet});
                        }

                        if (save_inline) {
                            stylesheet = md_dir.realpathAlloc(allocator, stylesheet) catch stylesheet;
                        }
                        try frontmatter.stylesheets.?.append(allocator, .{
                            .path = try utils.htmlEscape(allocator, stylesheet),
                            .save_inline = save_inline,
                        });
                    } else if (std.mem.startsWith(u8, next_line, "js: ")) {
                        var js = next_line[4..];
                        var save_inline = false;
                        if (std.mem.endsWith(u8, js, " - inline")) {
                            save_inline = true;
                            js = js[0 .. js.len - " - inline".len];
                            js = std.mem.trimRight(u8, js, " \t");
                        }
                        if (js[0] == '"' and js[js.len - 1] == '"') {
                            js = js[1 .. js.len - 1];
                        } else if (js[0] == '\'' and js[js.len - 1] == '\'') {
                            js = js[1 .. js.len - 1];
                        }
                        if (!save_inline and !(std.mem.startsWith(u8, js, "http://") or std.mem.startsWith(u8, js, "https://"))) {
                            js = try std.fmt.allocPrint(allocator, "/{s}", .{js});
                        }
                        if (save_inline) {
                            js = md_dir.realpathAlloc(allocator, js) catch js;
                        }
                        try frontmatter.scripts.?.append(allocator, .{
                            .path = try utils.htmlEscape(allocator, js),
                            .save_inline = save_inline,
                        });
                    }
                    line_idx += 1;
                }
            }
            try writeBase(allocator, &new_file, frontmatter);
            continue;
        } else if (line_idx == 0) {
            try writeBase(allocator, &new_file, .{ .title = null });
            line_idx += 1;
        }

        if (line.len == 0) {
            if (paragraph_buffer.items.len > 0) {
                const value = try std.mem.join(allocator, " ", paragraph_buffer.items);
                try writeTag(allocator, new_file, "p", value, &pending_id);
                paragraph_buffer.clearRetainingCapacity();
            }

            if (inBlockQuote) {
                inBlockQuote = false;
                try new_file.writeAll("</blockquote>\n");
            }
            while (list_stack.pop()) |entry| {
                switch (entry.list_type) {
                    .ul => try new_file.writeAll("</ul>\n"),
                    .ol => try new_file.writeAll("</ol>\n"),
                }
            }
            continue;
        }

        if (std.mem.lastIndexOf(u8, line, "---") != null or std.mem.lastIndexOf(u8, line, "***") != null) {
            try new_file.writeAll("<hr>\n");
            continue;
        }

        if (inBlockQuote) {
            if (trimmed.len > 0 and trimmed[0] == '>') {
                trimmed = trimmed[1..];
            } else {
                inBlockQuote = false;
                try new_file.writeAll("</blockquote>\n");
            }
        } else if (trimmed.len > 0 and trimmed[0] == '>') {
            inBlockQuote = true;
            try new_file.writeAll("<blockquote");
            if (pending_id) |id| {
                try new_file.writeAll(" id=\"");
                try new_file.writeAll(id);
                try new_file.writeAll("\"");
                pending_id = null;
            }
            try new_file.writeAll(">\n");
            trimmed = trimmed[1..];
        }

        if (tables.isTableLine(line)) {
            if (lines.peek()) |next_line| {
                if (tables.isTableSeparator(next_line)) {
                    try new_file.writeAll("<table");
                    if (pending_id) |id| {
                        try new_file.writeAll(" id=\"");
                        try new_file.writeAll(id);
                        try new_file.writeAll("\"");
                        pending_id = null;
                    }
                    try new_file.writeAll(">\n<tr>");
                    const headers = try tables.splitTableRow(allocator, line);
                    for (headers) |header| {
                        var cell = tables.extractCellId(header);
                        try writeTag(allocator, new_file, "th", cell.content, &cell.id);
                    }
                    try new_file.writeAll("</tr>\n");
                    _ = lines.next();

                    while (lines.peek()) |row| {
                        if (!tables.isTableLine(row)) {
                            break;
                        }
                        _ = lines.next();
                        try new_file.writeAll("<tr>");
                        const cells = try tables.splitTableRow(allocator, row);
                        for (cells) |column| {
                            var cell = tables.extractCellId(column);
                            try writeTag(allocator, new_file, "td", cell.content, &cell.id);
                        }
                        try new_file.writeAll("</tr>\n");
                    }
                    try new_file.writeAll("</table>\n");
                    continue;
                }
            }
        }

        var is_ul = false;
        var is_ol = false;
        var li_content: ?string = null;

        if (trimmed.len > 2 and (trimmed[0] == '-')) {
            is_ul = true;
            li_content = trimmed[2..];
        } else if (trimmed.len > 1 and std.ascii.isDigit(trimmed[0])) {
            var next: usize = 1;
            while (next < trimmed.len and std.ascii.isDigit(trimmed[next])) : (next += 1) {}
            if (trimmed[next] == '.') {
                is_ol = true;
                li_content = trimmed[next + 1 ..];
            }
        }

        if (is_ul or is_ol) {
            const list_type: ListType = if (is_ul) .ul else .ol;
            while (list_stack.items.len < indent + 1) {
                try new_file.writeAll(if (list_type == .ul) "<ul" else "<ol");
                if (pending_id) |id| {
                    try new_file.writeAll(" id=\"");
                    try new_file.writeAll(id);
                    try new_file.writeAll("\"");
                    pending_id = null;
                }
                try new_file.writeAll(">\n");
                try list_stack.append(allocator, .{ .list_type = list_type, .indent = indent });
            }

            while (list_stack.items.len > indent + 1) {
                const last = list_stack.pop();
                if (last) |entry| {
                    try new_file.writeAll(if (entry.list_type == .ul) "</ul>\n" else "</ol>\n");
                }
            }

            if (list_stack.items.len > 0 and list_stack.items[list_stack.items.len - 1].list_type != list_type) {
                const last = list_stack.pop();
                if (last) |entry| {
                    try new_file.writeAll(if (entry.list_type == .ul) "</ul>\n" else "</ol>\n");
                    try new_file.writeAll(if (list_type == .ul) "<ul" else "<ol");
                    if (pending_id) |id| {
                        try new_file.writeAll(" id=\"");
                        try new_file.writeAll(id);
                        try new_file.writeAll("\"");
                        pending_id = null;
                    }
                    try new_file.writeAll(">\n");
                    try list_stack.append(allocator, .{ .list_type = list_type, .indent = indent });
                }
            }

            if (li_content) |content| {
                try writeTag(allocator, new_file, "li", content, &pending_id);
            }
            continue;
        } else {
            while (list_stack.items.len > 0) {
                const last = list_stack.pop();
                if (last) |entry| {
                    try new_file.writeAll(if (entry.list_type == .ul) "</ul>\n" else "</ol>\n");
                }
            }
        }

        var prefix: string = "";
        if (trimmed.len > 0 and
            (std.mem.startsWith(u8, trimmed, "#") or
                std.mem.startsWith(u8, trimmed, "```")))
        {
            const idx = std.mem.indexOf(u8, trimmed, " ");
            if (idx) |i| {
                prefix = trimmed[0..i];
                trimmed = trimmed[i + 1 ..];
            } else {
                prefix = trimmed;
            }
        }

        if (inCodeBlock) {
            if (std.mem.eql(u8, prefix, "```")) {
                inCodeBlock = false;
                try new_file.writeAll("</pre>\n");
                continue;
            } else {
                try new_file.writeAll(line);
                try new_file.writeAll("\n");
                continue;
            }
        } else if (std.mem.eql(u8, prefix, "```")) {
            inCodeBlock = true;
            try new_file.writeAll("<pre");
            if (pending_id) |id| {
                try new_file.writeAll(" id=\"");
                try new_file.writeAll(id);
                try new_file.writeAll("\"");
                pending_id = null;
            }
            try new_file.writeAll(">\n");
            continue;
        }

        if (trimmed.len > 0 and
            (std.mem.startsWith(u8, trimmed, "#") or
                std.mem.startsWith(u8, trimmed, "```")))
        {
            const idx = std.mem.indexOf(u8, trimmed, " ");
            if (idx) |i| {
                prefix = trimmed[0..i];
                trimmed = trimmed[i + 1 ..];
            } else {
                prefix = trimmed;
            }
        }

        if (std.mem.eql(u8, prefix, "#")) {
            const cleaned = try utils.htmlEscape(allocator, trimmed);
            try writeTag(allocator, new_file, "h1", cleaned, &pending_id);
        } else if (std.mem.eql(u8, prefix, "##")) {
            const cleaned = try utils.htmlEscape(allocator, trimmed);
            try writeTag(allocator, new_file, "h2", cleaned, &pending_id);
        } else if (std.mem.eql(u8, prefix, "###")) {
            const cleaned = try utils.htmlEscape(allocator, trimmed);
            try writeTag(allocator, new_file, "h3", cleaned, &pending_id);
        } else if (std.mem.eql(u8, prefix, "")) {
            const cleaned = try utils.htmlEscape(allocator, trimmed);
            // try writeTag(allocator, new_file, "p", cleaned, &pending_id);
            try paragraph_buffer.append(allocator, cleaned);
        } else {
            std.debug.print("Unknown prefix: {s}\n", .{prefix});
        }
    }

    while (list_stack.items.len > 0) {
        const last = list_stack.pop();
        if (last) |entry| {
            try new_file.writeAll(if (entry.list_type == .ul) "</ul>\n" else "</ol>\n");
        }
    }

    if (paragraph_buffer.items.len > 0) {
        const value = try std.mem.join(allocator, " ", paragraph_buffer.items);
        try writeTag(allocator, new_file, "p", value, &pending_id);
        paragraph_buffer.clearRetainingCapacity();
    }

    try new_file.writeAll(footer);
}

fn closeListsIfNeeded(file: *std.fs.File, inUList: *bool, inOList: *bool) !void {
    if (inUList.*) {
        try file.*.writeAll("</ul>\n");
        inUList.* = false;
    }
    if (inOList.*) {
        try file.*.writeAll("</ol>\n");
        inOList.* = false;
    }
}
