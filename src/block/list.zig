/// List item classification — unordered, ordered, and task list markers.
const std = @import("std");
const Block = @import("root.zig");

pub const ListItem = struct {
    tag: Block.Tag,
    content: []const u8,
    indent: u8,
    checked: ?bool,
};

/// Classify a line as a list item (ul or ol) or return null.
pub fn classifyListItem(line: []const u8) ?ListItem {
    // Count leading spaces (indent level)
    var indent: u8 = 0;
    var pos: usize = 0;
    while (pos < line.len and line[pos] == ' ') {
        indent += 1;
        pos += 1;
    }
    if (pos >= line.len) return null;

    var tag: Block.Tag = undefined;
    var content: []const u8 = undefined;

    if (line[pos] == '-' or line[pos] == '*' or line[pos] == '+') {
        // Unordered list marker: must be followed by space
        if (pos + 1 >= line.len or line[pos + 1] != ' ') return null;
        tag = .ul_item;
        content = line[pos + 2 ..];
    } else if (std.ascii.isDigit(line[pos])) {
        // Ordered list marker: digits followed by . or ) then space
        var dpos = pos;
        while (dpos < line.len and std.ascii.isDigit(line[dpos])) dpos += 1;
        if (dpos >= line.len) return null;
        if (line[dpos] != '.' and line[dpos] != ')') return null;
        if (dpos + 1 >= line.len or line[dpos + 1] != ' ') return null;
        tag = .ol_item;
        content = line[dpos + 2 ..];
    } else {
        return null;
    }

    // Task list marker: [ ] or [x] or [X] at start of content
    var checked: ?bool = null;
    if (tag == .ul_item and content.len >= 3 and content[0] == '[') {
        if (content[1] == ' ' and content[2] == ']') {
            checked = false;
            content = if (content.len > 3) content[4..] else content[3..];
        } else if ((content[1] == 'x' or content[1] == 'X') and content[2] == ']') {
            checked = true;
            content = if (content.len > 3) content[4..] else content[3..];
        }
    }

    return .{
        .tag = tag,
        .content = content,
        .indent = indent,
        .checked = checked,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "classifyListItem — dash" {
    const item = classifyListItem("- hello").?;
    try testing.expectEqual(.ul_item, item.tag);
    try testing.expectEqualStrings("hello", item.content);
    try testing.expectEqual(0, item.indent);
}

test "classifyListItem — asterisk" {
    const item = classifyListItem("* world").?;
    try testing.expectEqual(.ul_item, item.tag);
    try testing.expectEqualStrings("world", item.content);
}

test "classifyListItem — plus" {
    const item = classifyListItem("+ item").?;
    try testing.expectEqual(.ul_item, item.tag);
}

test "classifyListItem — ordered dot" {
    const item = classifyListItem("1. first").?;
    try testing.expectEqual(.ol_item, item.tag);
    try testing.expectEqualStrings("first", item.content);
}

test "classifyListItem — ordered paren" {
    const item = classifyListItem("2) second").?;
    try testing.expectEqual(.ol_item, item.tag);
}

test "classifyListItem — indented" {
    const item = classifyListItem("  - nested").?;
    try testing.expectEqual(.ul_item, item.tag);
    try testing.expectEqual(2, item.indent);
}

test "classifyListItem — task unchecked" {
    const item = classifyListItem("- [ ] todo").?;
    try testing.expectEqual(.ul_item, item.tag);
    try testing.expectEqual(false, item.checked.?);
    try testing.expectEqualStrings("todo", item.content);
}

test "classifyListItem — task checked" {
    const item = classifyListItem("- [x] done").?;
    try testing.expectEqual(true, item.checked.?);
}

test "classifyListItem — not a list" {
    try testing.expectEqual(null, classifyListItem("hello"));
}

test "classifyListItem — dash without space" {
    try testing.expectEqual(null, classifyListItem("-nope"));
}

test "classifyListItem — multi-digit ordered" {
    const item = classifyListItem("123. big").?;
    try testing.expectEqual(.ol_item, item.tag);
    try testing.expectEqualStrings("big", item.content);
}
