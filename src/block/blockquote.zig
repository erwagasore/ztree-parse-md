/// Blockquote prefix stripping — `> ` or `>`.

/// Strip the `>` prefix from a blockquote line, or return null.
pub fn stripBlockquotePrefix(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '>') return null;
    if (line.len > 1 and line[1] == ' ') return line[2..];
    return line[1..];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "stripBlockquotePrefix — with space" {
    try testing.expectEqualStrings("hello", stripBlockquotePrefix("> hello").?);
}

test "stripBlockquotePrefix — without space" {
    try testing.expectEqualStrings("hello", stripBlockquotePrefix(">hello").?);
}

test "stripBlockquotePrefix — empty after marker" {
    try testing.expectEqualStrings("", stripBlockquotePrefix(">").?);
}

test "stripBlockquotePrefix — not a blockquote" {
    try testing.expectEqual(null, stripBlockquotePrefix("hello"));
}

test "stripBlockquotePrefix — empty line" {
    try testing.expectEqual(null, stripBlockquotePrefix(""));
}

test "stripBlockquotePrefix — nested" {
    try testing.expectEqualStrings("> inner", stripBlockquotePrefix("> > inner").?);
}
