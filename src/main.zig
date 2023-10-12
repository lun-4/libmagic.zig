const std = @import("std");
const testing = std.testing;

pub const c = @cImport({
    @cInclude("magic.h");
});

const logger = std.log.scoped(.libmagic);

// Claler owns returned memory.
fn loadStaticMagic(allocator: std.mem.Allocator) ![:0]const u8 {
    const datadir = try std.fs.getAppDataDir(allocator, "libmagic.zig");
    defer allocator.free(datadir);
    logger.warn("data dir {s}", .{datadir});

    _ = std.fs.openDirAbsolute(datadir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.fs.cwd().makePath(datadir);
        },
        else => return err,
    };

    var magic_filename: []const u8 = undefined;
    var magic_filename_buf: [32]u8 = undefined;
    // TODO move this bufPrint back to comptime
    magic_filename = std.fmt.bufPrint(
        &magic_filename_buf,
        "magic{d}.mgc",
        .{c.MAGIC_VERSION},
    ) catch unreachable;

    const database_file_path = try std.fs.path.join(allocator, &[_][]const u8{ datadir, magic_filename });
    defer allocator.free(database_file_path);

    std.fs.accessAbsolute(database_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            logger.warn("dumping static into {s}", .{database_file_path});

            const database_file = try std.fs.createFileAbsolute(database_file_path, .{ .truncate = true });
            defer database_file.close();

            // lmao who here 7mb binary
            const magic_file_data = @embedFile("magic.mgc");
            _ = try database_file.write(magic_file_data);
        },
        else => return err,
    };

    const database_file_cstr = try allocator.dupeZ(u8, database_file_path);
    return database_file_cstr;
}

const POSSIBLE_MAGICDB_PREFIXES = [_][:0]const u8{
    "/usr/share/misc/magic",
    "/usr/share/misc",
    "/usr/local/share/misc",
    "/etc",
};

fn findSystemMagicFile(allocator: std.mem.Allocator) !?[:0]const u8 {
    var found_prefix: ?usize = null;

    for (POSSIBLE_MAGICDB_PREFIXES, 0..) |prefix, prefix_index| {
        var dir = std.fs.cwd().openDir(prefix, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer dir.close();

        var magic_file = dir.openFile("magic.mgc", .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer magic_file.close();

        // we have a magic_file
        found_prefix = prefix_index;
        break;
    }

    const magicdb_prefix = POSSIBLE_MAGICDB_PREFIXES[
        found_prefix orelse return null
    ];

    const magicdb_path = try std.fmt.allocPrint(allocator, "{s}/magic", .{magicdb_prefix});
    defer allocator.free(magicdb_path);

    const path_cstr = try allocator.dupeZ(u8, magicdb_path);
    return path_cstr;
}

fn check(cookie: c.magic_t, path: [:0]const u8) !void {
    logger.warn("checking path {s}", .{path});
    if (c.magic_check(cookie, path.ptr) == -1) {
        const magic_error_value = c.magic_error(cookie);
        logger.err("failed to check magic file {s}: {s}", .{ path, magic_error_value });
        return error.MagicFileCheckFail;
    }
}

fn load(cookie: c.magic_t, path: [:0]const u8) !void {
    if (c.magic_load(cookie, path.ptr) == -1) {
        const magic_error_value = c.magic_error(cookie);
        logger.warn("failed to load magic file from {s}: {s}", .{ path, magic_error_value });
        return error.MagicLoadFail;
    }
    const magic_error_value_afterload = c.magic_error(cookie);
    if (magic_error_value_afterload != null) {
        logger.warn("failed to load magic file from {s}: {s}", .{ path, magic_error_value_afterload });
        return error.MagicLoadFail;
    }

    try check(cookie, path);
}

pub const MimeCookie = struct {
    cookie: c.magic_t,

    const Self = @This();

    const LoadingMode = enum {
        system_only,
        static_only,
        fallback_to_static,
    };

    const InitOptions = struct {
        loading_mode: LoadingMode = .fallback_to_static,
    };

    pub fn init(allocator: std.mem.Allocator, options: InitOptions) !Self {
        var cookie = c.magic_open(
            c.MAGIC_MIME_TYPE | c.MAGIC_CHECK | c.MAGIC_SYMLINK | c.MAGIC_ERROR,
        ) orelse return error.MagicCookieFail;

        const maybe_system_magic = if (options.loading_mode == .static_only) null else try findSystemMagicFile(allocator);
        defer if (maybe_system_magic) |system_magic| allocator.free(system_magic);

        const maybe_bundled_magic = if (options.loading_mode == .system_only) null else try loadStaticMagic(allocator);
        defer if (maybe_bundled_magic) |bundled_magic| allocator.free(bundled_magic);

        // try system magic first,
        // if that fails, fallback to static magic (should always work);

        var path: [:0]const u8 = undefined;

        if (maybe_system_magic) |system_magic| {
            logger.warn("loading magic file {s}", .{system_magic});
            load(cookie, system_magic) catch |err| {
                if (maybe_bundled_magic) |bundled_magic| {
                    try load(cookie, bundled_magic);
                    path = bundled_magic;
                } else {
                    return err;
                }
            };
            path = system_magic;
        } else {
            // if no system, use bundled already
            if (maybe_bundled_magic) |bundled_magic| {
                try load(cookie, bundled_magic);
                path = bundled_magic;
            } else {
                return error.MagicFileNotFoundInSystem;
            }
        }

        return MimeCookie{ .cookie = cookie };
    }

    pub fn deinit(self: Self) void {
        c.magic_close(self.cookie);
    }

    pub fn inferFile(self: Self, path: [:0]const u8) ![]const u8 {
        // TODO: remove ptrCast workaround for possible stage2 bug
        // "error: expected type '[*c]const u8', found '[:0]u8'"
        const mimetype = c.magic_file(self.cookie, path.ptr) orelse {
            const magic_error_value = c.magic_error(self.cookie);
            logger.err("failed to infer mimetype: {s}", .{magic_error_value});
            return error.MimetypeFail;
        };
        return std.mem.span(mimetype);
    }
};

test "magic time" {
    var cookie = try MimeCookie.init(std.testing.allocator, .{});
    defer cookie.deinit();

    const mimetype = try cookie.inferFile("src/test_vectors/audio_test_vector.mp3");
    logger.warn("mime: {s}", .{mimetype});
    try std.testing.expectEqualSlices(u8, "audio/mpeg", mimetype);
}
