/// Simple line-level classifiers — blank lines and thematic breaks.
const std = @import("std");

/// A blank line is empty or contains only spaces/tabs.
pub fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

/// A thematic break is a line with three or more `-`, `*`, or `_` (with optional spaces).
pub fn isThematicBreak(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    const marker = trimmed[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;
    for (trimmed) |c| {
        if (c != marker and c != ' ') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isBlankLine — empty string" {
    try testing.expect(isBlankLine(""));
}

test "isBlankLine — spaces only" {
    try testing.expect(isBlankLine("   "));
}

test "isBlankLine — tab" {
    try testing.expect(isBlankLine("\t"));
}

test "isBlankLine — non-blank" {
    try testing.expect(!isBlankLine("hello"));
}

test "isBlankLine — leading space then text" {
    try testing.expect(!isBlankLine("  x"));
}

test "isThematicBreak — dashes" {
    try testing.expect(isThematicBreak("---"));
}

test "isThematicBreak — dashes with spaces" {
    try testing.expect(isThematicBreak("- - -"));
}

test "isThematicBreak — asterisks" {
    try testing.expect(isThematicBreak("***"));
}

test "isThematicBreak — underscores" {
    try testing.expect(isThematicBreak("___"));
}

test "isThematicBreak — long run" {
    try testing.expect(isThematicBreak("----------"));
}

test "isThematicBreak — too short" {
    try testing.expect(!isThematicBreak("--"));
}

test "isThematicBreak — mixed markers" {
    try testing.expect(!isThematicBreak("-*-"));
}

test "isThematicBreak — text line" {
    try testing.expect(!isThematicBreak("hello"));
}

test "isThematicBreak — leading spaces preserved" {
    try testing.expect(isThematicBreak("   ---"));
}
