/// Footnote definition classification — `[^id]: content`.

pub const FootnoteDef = struct {
    id: []const u8,
    content: []const u8,
};

/// Classify a line as a footnote definition or return null.
/// Pattern: `[^id]: content` where id is one or more non-] characters.
pub fn classifyFootnoteDef(line: []const u8) ?FootnoteDef {
    if (line.len < 5) return null; // minimum: [^x]:
    if (line[0] != '[' or line[1] != '^') return null;

    // Find closing ]
    var pos: usize = 2;
    while (pos < line.len and line[pos] != ']') pos += 1;
    if (pos == 2) return null; // empty id
    if (pos >= line.len) return null; // no closing ]
    const id = line[2..pos];

    // Must have : after ]
    pos += 1;
    if (pos >= line.len or line[pos] != ':') return null;
    pos += 1;

    // Optional space after :
    if (pos < line.len and line[pos] == ' ') pos += 1;

    return .{
        .id = id,
        .content = line[pos..],
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "classifyFootnoteDef — basic" {
    const f = classifyFootnoteDef("[^1]: First footnote.").?;
    try testing.expectEqualStrings("1", f.id);
    try testing.expectEqualStrings("First footnote.", f.content);
}

test "classifyFootnoteDef — named label" {
    const f = classifyFootnoteDef("[^note]: Some text here.").?;
    try testing.expectEqualStrings("note", f.id);
    try testing.expectEqualStrings("Some text here.", f.content);
}

test "classifyFootnoteDef — no space after colon" {
    const f = classifyFootnoteDef("[^x]:content").?;
    try testing.expectEqualStrings("x", f.id);
    try testing.expectEqualStrings("content", f.content);
}

test "classifyFootnoteDef — empty content" {
    const f = classifyFootnoteDef("[^id]: ").?;
    try testing.expectEqualStrings("id", f.id);
    try testing.expectEqualStrings("", f.content);
}

test "classifyFootnoteDef — not a footnote" {
    try testing.expectEqual(null, classifyFootnoteDef("not a footnote"));
    try testing.expectEqual(null, classifyFootnoteDef("[text](url)"));
    try testing.expectEqual(null, classifyFootnoteDef("[^]: empty id"));
    try testing.expectEqual(null, classifyFootnoteDef("[^no-colon]"));
}
