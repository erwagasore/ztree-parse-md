/// ATX heading classification — `# ` through `###### `.
const std = @import("std");
const Block = @import("root.zig");

pub const Heading = struct {
    tag: Block.Tag,
    content: []const u8,
};

/// Classify a line as an ATX heading (h1–h6) or return null.
pub fn classifyHeading(line: []const u8) ?Heading {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] != '#') return null;

    var level: usize = 0;
    while (level < trimmed.len and trimmed[level] == '#') level += 1;
    if (level > 6) return null;
    if (level < trimmed.len and trimmed[level] != ' ') return null;

    const content_start = if (level < trimmed.len) level + 1 else level;
    const tag: Block.Tag = switch (level) {
        1 => .h1,
        2 => .h2,
        3 => .h3,
        4 => .h4,
        5 => .h5,
        6 => .h6,
        else => unreachable,
    };
    return .{ .tag = tag, .content = trimmed[content_start..] };
}

/// Classify a line as a setext heading underline.
/// Returns .h1 for `===...` or .h2 for `---...`, null otherwise.
/// The line must contain only the marker character (and optional leading/trailing spaces).
pub fn classifySetextUnderline(line: []const u8) ?Block.Tag {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;

    const ch = trimmed[0];
    if (ch != '=' and ch != '-') return null;

    for (trimmed) |c| {
        if (c != ch) return null;
    }

    // Need at least 1 char for = (any count works), and 1 for - but
    // --- with 3+ is a thematic break which is checked earlier.
    // Setext underlines need a preceding paragraph to be valid,
    // so the caller handles that context.
    if (ch == '=') return .h1;
    return .h2;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "classifyHeading — h1" {
    const h = classifyHeading("# Hello").?;
    try testing.expectEqual(.h1, h.tag);
    try testing.expectEqualStrings("Hello", h.content);
}

test "classifyHeading — h6" {
    const h = classifyHeading("###### Deep").?;
    try testing.expectEqual(.h6, h.tag);
    try testing.expectEqualStrings("Deep", h.content);
}

test "classifyHeading — too many hashes" {
    try testing.expectEqual(null, classifyHeading("####### Nope"));
}

test "classifyHeading — no space" {
    try testing.expectEqual(null, classifyHeading("#NoSpace"));
}

test "classifyHeading — empty after hash" {
    const h = classifyHeading("## ").?;
    try testing.expectEqual(.h2, h.tag);
    try testing.expectEqualStrings("", h.content);
}

test "classifyHeading — plain text" {
    try testing.expectEqual(null, classifyHeading("Hello"));
}

test "classifyHeading — leading spaces" {
    const h = classifyHeading("  ## Indented").?;
    try testing.expectEqual(.h2, h.tag);
    try testing.expectEqualStrings("Indented", h.content);
}

test "classifyHeading — lone hash" {
    const h = classifyHeading("#").?;
    try testing.expectEqual(.h1, h.tag);
    try testing.expectEqualStrings("", h.content);
}

test "classifySetextUnderline — equals h1" {
    try testing.expectEqual(.h1, classifySetextUnderline("==="));
    try testing.expectEqual(.h1, classifySetextUnderline("="));
    try testing.expectEqual(.h1, classifySetextUnderline("  ===  "));
}

test "classifySetextUnderline — dashes h2" {
    try testing.expectEqual(.h2, classifySetextUnderline("---"));
    try testing.expectEqual(.h2, classifySetextUnderline("-"));
    try testing.expectEqual(.h2, classifySetextUnderline("  ---  "));
}

test "classifySetextUnderline — mixed chars not valid" {
    try testing.expectEqual(null, classifySetextUnderline("=-="));
    try testing.expectEqual(null, classifySetextUnderline("==-"));
}

test "classifySetextUnderline — empty" {
    try testing.expectEqual(null, classifySetextUnderline(""));
    try testing.expectEqual(null, classifySetextUnderline("   "));
}
