/// ztree-parse-md — GFM Markdown parser for ztree.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;

/// Parse Markdown text into a ztree Node tree.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Node {
    const blocks = try parseBlocks(allocator, input);
    return buildTree(allocator, blocks);
}

// ---------------------------------------------------------------------------
// Pass 1 — Block scanner
// ---------------------------------------------------------------------------

const Tag = enum { h1, h2, h3, h4, h5, h6, p };

const Block = struct {
    tag: Tag,
    content: []const u8,
};

/// Scan input line-by-line and produce a flat list of Block descriptors.
fn parseBlocks(allocator: std.mem.Allocator, input: []const u8) ![]const Block {
    var blocks: std.ArrayList(Block) = .empty;

    var para_start: ?usize = null;
    var para_end: usize = 0;

    var pos: usize = 0;
    while (pos < input.len) {
        const line_start = pos;
        const line_end = if (std.mem.indexOfScalar(u8, input[pos..], '\n')) |nl| pos + nl else input.len;
        const line = input[line_start..line_end];
        pos = if (line_end < input.len) line_end + 1 else input.len;

        if (isBlankLine(line)) {
            // Flush any open paragraph
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            continue;
        }

        if (classifyHeading(line)) |heading| {
            // Flush any open paragraph first
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            try blocks.append(allocator, .{ .tag = heading.tag, .content = heading.content });
            continue;
        }

        // Paragraph line
        if (para_start == null) {
            para_start = line_start;
        }
        para_end = line_end;
    }

    // Flush trailing paragraph
    if (para_start) |start| {
        try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
    }

    return try blocks.toOwnedSlice(allocator);
}

const Heading = struct {
    tag: Tag,
    content: []const u8,
};

/// Classify a line as a heading if it starts with 1–6 '#' followed by a space.
/// Returns null if not a heading.
fn classifyHeading(line: []const u8) ?Heading {
    var level: usize = 0;
    while (level < line.len and level < 6 and line[level] == '#') {
        level += 1;
    }

    // Must have at least one '#', followed by a space (or be just '#' chars at EOL)
    if (level == 0) return null;
    if (level < line.len and line[level] != ' ') return null;

    const content_start = if (level < line.len) level + 1 else level;
    const content = line[content_start..];

    const tag: Tag = switch (level) {
        1 => .h1,
        2 => .h2,
        3 => .h3,
        4 => .h4,
        5 => .h5,
        6 => .h6,
        else => unreachable,
    };

    return .{ .tag = tag, .content = content };
}

/// A line is blank if it contains only whitespace.
fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Pass 2 — Tree builder
// ---------------------------------------------------------------------------

/// Convert a list of Blocks into a ztree Node tree (a fragment of top-level elements).
fn buildTree(allocator: std.mem.Allocator, blocks: []const Block) !Node {
    if (blocks.len == 0) return .{ .fragment = &.{} };

    const nodes = try allocator.alloc(Node, blocks.len);
    for (blocks, 0..) |block, i| {
        const children = try allocator.alloc(Node, 1);
        children[0] = .{ .text = block.content };
        nodes[i] = .{ .element = .{
            .tag = tagName(block.tag),
            .attrs = &.{},
            .children = children,
        } };
    }

    return .{ .fragment = nodes };
}

fn tagName(tag: Tag) []const u8 {
    return switch (tag) {
        .h1 => "h1",
        .h2 => "h2",
        .h3 => "h3",
        .h4 => "h4",
        .h5 => "h5",
        .h6 => "h6",
        .p => "p",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Expect a fragment with the given number of children.
fn expectFragment(node: Node, expected_len: usize) ![]const Node {
    try testing.expectEqual(.fragment, std.meta.activeTag(node));
    try testing.expectEqual(expected_len, node.fragment.len);
    return node.fragment;
}

/// Expect an element with the given tag and a single text child.
fn expectTextElement(node: Node, expected_tag: []const u8, expected_text: []const u8) !void {
    try testing.expectEqual(.element, std.meta.activeTag(node));
    try testing.expectEqualStrings(expected_tag, node.element.tag);
    try testing.expectEqual(0, node.element.attrs.len);
    try testing.expectEqual(1, node.element.children.len);
    try testing.expectEqual(.text, std.meta.activeTag(node.element.children[0]));
    try testing.expectEqualStrings(expected_text, node.element.children[0].text);
}

// -- helper unit tests --

test "isBlankLine — empty string" {
    try testing.expect(isBlankLine(""));
}

test "isBlankLine — spaces only" {
    try testing.expect(isBlankLine("   "));
}

test "isBlankLine — tabs and spaces" {
    try testing.expect(isBlankLine(" \t "));
}

test "isBlankLine — non-blank" {
    try testing.expect(!isBlankLine("hello"));
}

test "isBlankLine — leading space with content" {
    try testing.expect(!isBlankLine("  x"));
}

test "classifyHeading — h1" {
    const h = classifyHeading("# Hello").?;
    try testing.expectEqual(.h1, h.tag);
    try testing.expectEqualStrings("Hello", h.content);
}

test "classifyHeading — h3" {
    const h = classifyHeading("### Third").?;
    try testing.expectEqual(.h3, h.tag);
    try testing.expectEqualStrings("Third", h.content);
}

test "classifyHeading — h6" {
    const h = classifyHeading("###### Six").?;
    try testing.expectEqual(.h6, h.tag);
    try testing.expectEqualStrings("Six", h.content);
}

test "classifyHeading — seven hashes is not a heading" {
    try testing.expectEqual(null, classifyHeading("####### nope"));
}

test "classifyHeading — no space after hash is not a heading" {
    try testing.expectEqual(null, classifyHeading("#nope"));
}

test "classifyHeading — empty content after hash-space" {
    const h = classifyHeading("# ").?;
    try testing.expectEqual(.h1, h.tag);
    try testing.expectEqualStrings("", h.content);
}

test "classifyHeading — bare hash" {
    const h = classifyHeading("#").?;
    try testing.expectEqual(.h1, h.tag);
    try testing.expectEqualStrings("", h.content);
}

// -- parse: single elements --

test "single heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "# Hello");
    const nodes = try expectFragment(tree, 1);
    try expectTextElement(nodes[0], "h1", "Hello");
}

test "single paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Hello world");
    const nodes = try expectFragment(tree, 1);
    try expectTextElement(nodes[0], "p", "Hello world");
}

test "multi-line paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Line one\nLine two");
    const nodes = try expectFragment(tree, 1);
    try expectTextElement(nodes[0], "p", "Line one\nLine two");
}

// -- parse: multiple blocks --

test "heading then paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "# Title\n\nSome text.");
    const nodes = try expectFragment(tree, 2);
    try expectTextElement(nodes[0], "h1", "Title");
    try expectTextElement(nodes[1], "p", "Some text.");
}

test "two paragraphs separated by blank line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "First.\n\nSecond.");
    const nodes = try expectFragment(tree, 2);
    try expectTextElement(nodes[0], "p", "First.");
    try expectTextElement(nodes[1], "p", "Second.");
}

test "multiple blank lines between blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "First.\n\n\n\nSecond.");
    const nodes = try expectFragment(tree, 2);
    try expectTextElement(nodes[0], "p", "First.");
    try expectTextElement(nodes[1], "p", "Second.");
}

test "heading between paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Intro.\n\n## Section\n\nBody.");
    const nodes = try expectFragment(tree, 3);
    try expectTextElement(nodes[0], "p", "Intro.");
    try expectTextElement(nodes[1], "h2", "Section");
    try expectTextElement(nodes[2], "p", "Body.");
}

test "heading immediately after paragraph (no blank line)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Some text.\n# Heading");
    const nodes = try expectFragment(tree, 2);
    try expectTextElement(nodes[0], "p", "Some text.");
    try expectTextElement(nodes[1], "h1", "Heading");
}

test "all heading levels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6");
    const nodes = try expectFragment(tree, 6);
    try expectTextElement(nodes[0], "h1", "H1");
    try expectTextElement(nodes[1], "h2", "H2");
    try expectTextElement(nodes[2], "h3", "H3");
    try expectTextElement(nodes[3], "h4", "H4");
    try expectTextElement(nodes[4], "h5", "H5");
    try expectTextElement(nodes[5], "h6", "H6");
}

// -- parse: edge cases --

test "empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "");
    _ = try expectFragment(tree, 0);
}

test "only blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "\n\n\n");
    _ = try expectFragment(tree, 0);
}

test "trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Hello\n");
    const nodes = try expectFragment(tree, 1);
    try expectTextElement(nodes[0], "p", "Hello");
}

// -- zero-copy --

test "heading text is zero-copy — points into original input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "# Hello";
    const tree = try parse(arena.allocator(), input);
    const text_content = tree.fragment[0].element.children[0].text;
    try testing.expectEqualStrings("Hello", text_content);
    try testing.expect(text_content.ptr == input.ptr + 2);
}

test "multi-line paragraph is zero-copy — spans original input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "Line 1\nLine 2";
    const tree = try parse(arena.allocator(), input);
    const text_content = tree.fragment[0].element.children[0].text;
    try testing.expectEqualStrings("Line 1\nLine 2", text_content);
    try testing.expect(text_content.ptr == input.ptr);
}
