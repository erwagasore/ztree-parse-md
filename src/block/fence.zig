/// Fenced code block detection — opening and closing fences.
const std = @import("std");

pub const FenceOpen = struct {
    backtick_count: usize,
    lang: []const u8,
};

/// Classify a line as a fenced code block opening (>= 3 backticks, optional language).
pub fn classifyFenceOpen(line: []const u8) ?FenceOpen {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 3 or trimmed[0] != '`') return null;

    var count: usize = 0;
    while (count < trimmed.len and trimmed[count] == '`') count += 1;
    if (count < 3) return null;

    const lang = std.mem.trim(u8, trimmed[count..], " \t");
    return .{ .backtick_count = count, .lang = lang };
}

/// Check if a line closes a fenced code block (>= min_backticks, nothing else).
pub fn isClosingFence(line: []const u8, min_backticks: usize) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < min_backticks) return false;
    for (trimmed) |c| {
        if (c != '`') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "classifyFenceOpen — basic" {
    const f = classifyFenceOpen("```").?;
    try testing.expectEqual(3, f.backtick_count);
    try testing.expectEqualStrings("", f.lang);
}

test "classifyFenceOpen — with language" {
    const f = classifyFenceOpen("```zig").?;
    try testing.expectEqual(3, f.backtick_count);
    try testing.expectEqualStrings("zig", f.lang);
}

test "classifyFenceOpen — four backticks" {
    const f = classifyFenceOpen("````rust").?;
    try testing.expectEqual(4, f.backtick_count);
    try testing.expectEqualStrings("rust", f.lang);
}

test "classifyFenceOpen — too few backticks" {
    try testing.expectEqual(null, classifyFenceOpen("``"));
}

test "classifyFenceOpen — not backticks" {
    try testing.expectEqual(null, classifyFenceOpen("hello"));
}

test "isClosingFence — exact match" {
    try testing.expect(isClosingFence("```", 3));
}

test "isClosingFence — more backticks" {
    try testing.expect(isClosingFence("`````", 3));
}

test "isClosingFence — too few" {
    try testing.expect(!isClosingFence("``", 3));
}

test "isClosingFence — has other chars" {
    try testing.expect(!isClosingFence("```x", 3));
}
