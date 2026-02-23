/// Shared utilities used across block, inline, and tree modules.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;

// ---------------------------------------------------------------------------
// String helpers
// ---------------------------------------------------------------------------

/// Case-insensitive string comparison.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

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

// ---------------------------------------------------------------------------
// Line scanning helpers
// ---------------------------------------------------------------------------

/// Find the end of the current line starting at `pos`. Returns the index of '\n' or input.len.
pub fn nextLineEnd(input: []const u8, pos: usize) usize {
    return if (std.mem.indexOfScalar(u8, input[pos..], '\n')) |nl| pos + nl else input.len;
}

/// Advance past the current line ending. Returns position after '\n', or input.len.
pub fn nextLineStart(input: []const u8, line_end: usize) usize {
    return if (line_end < input.len) line_end + 1 else input.len;
}

// ---------------------------------------------------------------------------
// Node construction helpers
// ---------------------------------------------------------------------------

/// Create a single-text-child element node.
pub fn makeTextElement(allocator: std.mem.Allocator, tag: []const u8, text: []const u8) std.mem.Allocator.Error!Node {
    const children = try allocator.alloc(Node, 1);
    children[0] = .{ .text = text };
    return .{ .element = .{ .tag = tag, .attrs = &.{}, .children = children } };
}

/// Create an element with the given tag, a single attribute, and children.
pub fn makeElementWithAttr(allocator: std.mem.Allocator, tag: []const u8, key: []const u8, value: ?[]const u8, children: []const Node) std.mem.Allocator.Error!Node {
    const attrs = try allocator.alloc(ztree.Attr, 1);
    attrs[0] = .{ .key = key, .value = value };
    return .{ .element = .{ .tag = tag, .attrs = attrs, .children = children } };
}

/// Create a void element (no children) with the given attributes.
pub fn makeVoidElement(_: std.mem.Allocator, tag: []const u8, attrs: []const ztree.Attr) Node {
    return .{ .element = .{ .tag = tag, .attrs = attrs, .children = &.{} } };
}

/// Build an autolink node: a(href=url) with url as text child.
pub fn buildAutolinkNode(allocator: std.mem.Allocator, url: []const u8) std.mem.Allocator.Error!Node {
    const attrs = try allocator.alloc(ztree.Attr, 1);
    attrs[0] = .{ .key = "href", .value = url };
    const children = try allocator.alloc(Node, 1);
    children[0] = .{ .text = url };
    return .{ .element = .{ .tag = "a", .attrs = attrs, .children = children } };
}

// ---------------------------------------------------------------------------
// Inline text flushing
// ---------------------------------------------------------------------------

/// Flush pending text from content[text_start..pos] into the nodes list.
/// Returns the new text_start (= pos).
pub fn flushText(nodes: *std.ArrayList(Node), allocator: std.mem.Allocator, content: []const u8, text_start: usize, pos: usize) std.mem.Allocator.Error!void {
    if (text_start < pos) {
        try nodes.append(allocator, .{ .text = content[text_start..pos] });
    }
}
