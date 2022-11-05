const std = @import("std");
const testing = std.testing;

pub const c = @cImport({
    @cInclude("magic.h");
});

const magic_file_data = @embedFile("magic.mgc");

const logger = std.log.scoped(.libmagic);

const MimeCookie = struct {
    cookie: c.magic_t,

    const Self = @This();

    const POSSIBLE_MAGICDB_PREFIXES = [_][:0]const u8{
        "/usr/share/misc",
        "/usr/local/share/misc",
        "/etc",
    };

    const InitOptions = struct {
        static_magic_file: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, options: InitOptions) !Self {
        var cookie = c.magic_open(
            c.MAGIC_MIME_TYPE | c.MAGIC_CHECK | c.MAGIC_SYMLINK | c.MAGIC_ERROR,
        ) orelse return error.MagicCookieFail;

        if (options.static_magic_file) {
            const datadir = try std.fs.getAppDataDir(allocator, "libmagic");
            defer allocator.free(datadir);
            logger.warn("data dir {s}", .{datadir});

            _ = std.fs.openDirAbsolute(datadir, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try std.fs.makeDirAbsolute(datadir);
                },
                else => return err,
            };

            const database_file_path = try std.fs.path.join(allocator, &[_][]const u8{ datadir, "magic.mgc" });
            defer allocator.free(database_file_path);

            logger.warn("dumping static into {s}", .{database_file_path});

            const database_file = try std.fs.createFileAbsolute(database_file_path, .{ .truncate = true });
            defer database_file.close();
            _ = try database_file.write(magic_file_data);

            const database_file_cstr = try std.cstr.addNullByte(allocator, database_file_path);
            defer allocator.free(database_file_cstr);

            if (c.magic_load(cookie, database_file_cstr.ptr) == -1) {
                const magic_error_value = c.magic_error(cookie);
                logger.err("failed to load magic buffer: {s}", .{magic_error_value});
                return error.MagicFileFail;
            }

            if (c.magic_check(cookie, database_file_cstr.ptr) == -1) {
                const magic_error_value = c.magic_error(cookie);
                logger.err("failed to check magic file: {s}", .{magic_error_value});
                return error.MagicFileFail;
            }
        } else {
            // this attempts to find the path for the magic db file dynamically
            // through some paths i have found around the systems i have.
            //
            // libmagic's build process enables you to override the default
            // path to the magic file, which means that doing a static build of it
            // means it won't work on a separate system since it doesn't have
            // that one hardcoded in.
            //
            // a future iteration might bundle the magic database with the
            // executable through possibly, @embedFile, then dump that into a
            // temporary file for super compatibility with windows and macos

            var found_prefix: ?usize = null;

            for (POSSIBLE_MAGICDB_PREFIXES) |prefix, prefix_index| {
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
                found_prefix orelse {
                    logger.err("failed to locate magic file", .{});
                    return error.MagicNotFound;
                }
            ];

            const magicdb_path = try std.fmt.allocPrint(allocator, "{s}/magic", .{magicdb_prefix});
            defer allocator.free(magicdb_path);

            const path_cstr = try std.cstr.addNullByte(allocator, magicdb_path);
            defer allocator.free(path_cstr);

            logger.info("loading magic file at prefix {s}", .{path_cstr});

            if (c.magic_load(cookie, path_cstr.ptr) == -1) {
                const magic_error_value = c.magic_error(cookie);
                logger.err("failed to load magic file: {s}", .{magic_error_value});
                return error.MagicFileFail;
            }

            if (c.magic_check(cookie, path_cstr.ptr) == -1) {
                const magic_error_value = c.magic_error(cookie);
                logger.err("failed to check magic file: {s}", .{magic_error_value});
                return error.MagicFileFail;
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
