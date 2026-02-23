/// Inline code span handling — backtick matching and trimming.

/// Find closing backtick run of exactly `count` length, starting search at `start`.
pub fn findClosingBackticks(content: []const u8, start: usize, count: usize) ?usize {
    var pos = start;
    while (pos < content.len) {
        if (content[pos] == '`') {
            const run_start = pos;
            while (pos < content.len and content[pos] == '`') pos += 1;
            if (pos - run_start == count) return run_start;
        } else {
            pos += 1;
        }
    }
    return null;
}

/// CommonMark: if code span content begins AND ends with a space, but is not entirely
/// spaces, strip one leading and one trailing space.
pub fn trimCodeSpan(content: []const u8) []const u8 {
    if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ') {
        for (content) |c| {
            if (c != ' ') return content[1 .. content.len - 1];
        }
    }
    return content;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "findClosingBackticks — single" {
    try testing.expectEqual(5, findClosingBackticks("hello`world", 0, 1).?);
}

test "findClosingBackticks — double" {
    try testing.expectEqual(5, findClosingBackticks("hello``world", 0, 2).?);
}

test "findClosingBackticks — no match wrong count" {
    try testing.expectEqual(null, findClosingBackticks("hello`world", 0, 2));
}

test "findClosingBackticks — no match" {
    try testing.expectEqual(null, findClosingBackticks("hello world", 0, 1));
}

test "findClosingBackticks — skip wrong count then match" {
    try testing.expectEqual(9, findClosingBackticks("hello``ok`done", 0, 1).?);
}

test "trimCodeSpan — no trim" {
    try testing.expectEqualStrings("hello", trimCodeSpan("hello"));
}

test "trimCodeSpan — trim both" {
    try testing.expectEqualStrings("hello", trimCodeSpan(" hello "));
}

test "trimCodeSpan — all spaces not trimmed" {
    try testing.expectEqualStrings("   ", trimCodeSpan("   "));
}

test "trimCodeSpan — single space not trimmed" {
    try testing.expectEqualStrings(" ", trimCodeSpan(" "));
}
