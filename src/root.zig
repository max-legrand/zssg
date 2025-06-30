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
    defer md_files.deinit();

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

pub fn processFiles(allocator: std.mem.Allocator, md_files: []string) !void {
    // Process the files in parallel.
    var threads = std.ArrayList(std.Thread).init(allocator);
    defer threads.deinit();

    for (md_files) |md_file| {
        const thread = try std.Thread.spawn(.{}, processFile, .{ allocator, md_file });
        try threads.append(thread);

        if (threads.items.len == 4) {
            for (threads.items) |t| {
                t.join();
            }
            threads.clearAndFree();
        }
    }

    for (threads.items) |thread| {
        thread.join();
    }
}

const base =
    \\<doctype html>
    \\<head>
    \\</head>
    \\<body>
;

const footer =
    \\</body>
    \\</html>
;

fn processFile(allocator: std.mem.Allocator, md_file: string) !void {
    std.debug.print("Processing file: {s}\n", .{md_file});
    const file = try std.fs.openFileAbsolute(md_file, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    std.debug.print("Contents: {s}\n", .{contents});

    var headers = std.ArrayList(string).init(allocator);
    defer headers.deinit();

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "#")) {
            const cleaned_header = std.mem.trim(u8, trimmed, "# \t");
            try headers.append(cleaned_header);
        }
    }

    const filename = std.fs.path.basename(md_file);
    const ext = std.fs.path.extension(filename);
    const filename_without_ext = filename[0 .. filename.len - ext.len];
    const html_filename = try std.fmt.allocPrint(allocator, "{s}.html", .{filename_without_ext});
    defer allocator.free(html_filename);
    std.debug.print("Filename: {s}\n", .{html_filename});
}
