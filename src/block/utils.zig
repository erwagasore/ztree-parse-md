/// Block-level utilities — line joining.
const std = @import("std");

/// Join slices with newline separators into a single allocated buffer.
pub fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";

    var total: usize = 0;
    for (lines, 0..) |line, i| {
        total += line.len;
        if (i < lines.len - 1) total += 1;
    }

    const buf = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (lines, 0..) |line, i| {
        @memcpy(buf[pos .. pos + line.len], line);
        pos += line.len;
        if (i < lines.len - 1) {
            buf[pos] = '\n';
            pos += 1;
        }
    }
    return buf;
}
