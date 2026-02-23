/// Link and image handling — `[text](url)`, `![alt](src)`, and reference links `[text][ref]`.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;
const inlines = @import("root.zig");
const Block = @import("../block/root.zig");

pub const LinkResult = struct {
    node: Node,
    end: usize,
};

/// Try to build a link or image from `[text](url)`, `![alt](src)`,
/// or reference forms `[text][ref]`, `[text][]`, `[text]`.
pub fn handleLinkOrImage(allocator: std.mem.Allocator, content: []const u8, pos: usize, is_image: bool, ref_defs: []const Block.RefDef) std.mem.Allocator.Error!?LinkResult {
    const bracket_start: usize = if (is_image) pos + 2 else pos + 1;

    // Find closing ]
    const bracket_end = (std.mem.indexOfScalar(u8, content[bracket_start..], ']') orelse return null) + bracket_start;
    const text_content = content[bracket_start..bracket_end];

    // Try inline link: [text](url)
    if (bracket_end + 1 < content.len and content[bracket_end + 1] == '(') {
        const paren_start = bracket_end + 2;
        if (findClosingParen(content, paren_start)) |paren_end| {
            const url_content = content[paren_start..paren_end];
            const url_info = parseUrlTitle(url_content);
            return try buildLinkNode(allocator, text_content, url_info.url, url_info.title, is_image, paren_end + 1, ref_defs);
        }
    }

    // Try full reference: [text][ref]
    if (bracket_end + 1 < content.len and content[bracket_end + 1] == '[') {
        const ref_start = bracket_end + 2;
        if (std.mem.indexOfScalar(u8, content[ref_start..], ']')) |ref_close_offset| {
            const ref_end = ref_start + ref_close_offset;
            const ref_label = content[ref_start..ref_end];

            // Collapsed reference [text][] — use text as label
            const label = if (ref_label.len == 0) text_content else ref_label;

            if (Block.findRefDef(ref_defs, label)) |def| {
                return try buildLinkNode(allocator, text_content, def.url, def.title, is_image, ref_end + 1, ref_defs);
            }
        }
    }

    // Try shortcut reference: [text] — use text as label
    if (ref_defs.len > 0) {
        if (Block.findRefDef(ref_defs, text_content)) |def| {
            // Only match shortcut if not followed by ( or [
            if (bracket_end + 1 >= content.len or
                (content[bracket_end + 1] != '(' and content[bracket_end + 1] != '['))
            {
                return try buildLinkNode(allocator, text_content, def.url, def.title, is_image, bracket_end + 1, ref_defs);
            }
        }
    }

    return null;
}

fn buildLinkNode(allocator: std.mem.Allocator, text: []const u8, url: []const u8, title: ?[]const u8, is_image: bool, end: usize, ref_defs: []const Block.RefDef) std.mem.Allocator.Error!LinkResult {
    if (is_image) {
        const attr_count: usize = if (title != null) 3 else 2;
        const attrs = try allocator.alloc(ztree.Attr, attr_count);
        attrs[0] = .{ .key = "src", .value = url };
        attrs[1] = .{ .key = "alt", .value = text };
        if (title) |t| {
            attrs[2] = .{ .key = "title", .value = t };
        }
        return .{
            .node = .{ .element = .{ .tag = "img", .attrs = attrs, .children = &.{} } },
            .end = end,
        };
    } else {
        const attr_count: usize = if (title != null) 2 else 1;
        const attrs = try allocator.alloc(ztree.Attr, attr_count);
        attrs[0] = .{ .key = "href", .value = url };
        if (title) |t| {
            attrs[1] = .{ .key = "title", .value = t };
        }
        const children = try inlines.parseInlinesWithRefs(allocator, text, ref_defs);
        return .{
            .node = .{ .element = .{ .tag = "a", .attrs = attrs, .children = children } },
            .end = end,
        };
    }
}

/// Find closing `)` with balanced parentheses.
pub fn findClosingParen(content: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var pos = start;
    while (pos < content.len) {
        if (content[pos] == '(') {
            depth += 1;
        } else if (content[pos] == ')') {
            depth -= 1;
            if (depth == 0) return pos;
        }
        pos += 1;
    }
    return null;
}

pub const UrlTitle = struct {
    url: []const u8,
    title: ?[]const u8,
};

/// Parse URL and optional title from the content between `(` and `)`.
/// Supports `url`, `url "title"`, and `url 'title'`.
pub fn parseUrlTitle(content: []const u8) UrlTitle {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (trimmed.len < 2) return .{ .url = trimmed, .title = null };

    const last_char = trimmed[trimmed.len - 1];
    if (last_char == '"' or last_char == '\'') {
        // Search backwards for matching opening quote preceded by a space
        var i: usize = trimmed.len - 2;
        while (true) {
            if (trimmed[i] == last_char and i > 0 and trimmed[i - 1] == ' ') {
                return .{
                    .url = std.mem.trimEnd(u8, trimmed[0 .. i - 1], " \t"),
                    .title = trimmed[i + 1 .. trimmed.len - 1],
                };
            }
            if (i == 0) break;
            i -= 1;
        }
    }

    return .{ .url = trimmed, .title = null };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseUrlTitle — url only" {
    const result = parseUrlTitle("https://example.com");
    try testing.expectEqualStrings("https://example.com", result.url);
    try testing.expectEqual(null, result.title);
}

test "parseUrlTitle — url with double-quoted title" {
    const result = parseUrlTitle("url \"My Title\"");
    try testing.expectEqualStrings("url", result.url);
    try testing.expectEqualStrings("My Title", result.title.?);
}

test "parseUrlTitle — url with single-quoted title" {
    const result = parseUrlTitle("url 'My Title'");
    try testing.expectEqualStrings("url", result.url);
    try testing.expectEqualStrings("My Title", result.title.?);
}

test "parseUrlTitle — empty" {
    const result = parseUrlTitle("");
    try testing.expectEqualStrings("", result.url);
    try testing.expectEqual(null, result.title);
}
