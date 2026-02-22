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

const Tag = enum { h1, h2, h3, h4, h5, h6, p, pre };

const Block = struct {
    tag: Tag,
    content: []const u8,
    lang: []const u8 = "",
};

/// Scan input line-by-line and produce a flat list of Block descriptors.
fn parseBlocks(allocator: std.mem.Allocator, input: []const u8) ![]const Block {
    var blocks: std.ArrayList(Block) = .empty;

    var para_start: ?usize = null;
    var para_end: usize = 0;

    // Fence state
    var in_fence = false;
    var fence_backtick_count: usize = 0;
    var fence_lang: []const u8 = "";
    var fence_content_start: usize = 0;

    var pos: usize = 0;
    while (pos < input.len) {
        const line_start = pos;
        const line_end = if (std.mem.indexOfScalar(u8, input[pos..], '\n')) |nl| pos + nl else input.len;
        const line = input[line_start..line_end];
        pos = if (line_end < input.len) line_end + 1 else input.len;

        if (in_fence) {
            if (isClosingFence(line, fence_backtick_count)) {
                const content = if (fence_content_start < line_start)
                    input[fence_content_start..line_start]
                else
                    "";
                try blocks.append(allocator, .{ .tag = .pre, .content = content, .lang = fence_lang });
                in_fence = false;
            }
            // Lines inside fence are captured by the content slice — no action needed.
            continue;
        }

        if (isBlankLine(line)) {
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            continue;
        }

        if (classifyFenceOpen(line)) |fence| {
            // Flush any open paragraph first
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            in_fence = true;
            fence_backtick_count = fence.backtick_count;
            fence_lang = fence.lang;
            fence_content_start = pos; // start of next line
            continue;
        }

        if (classifyHeading(line)) |heading| {
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

    // Unclosed fence — content runs to end of input
    if (in_fence) {
        const content = if (fence_content_start < input.len)
            input[fence_content_start..]
        else
            "";
        try blocks.append(allocator, .{ .tag = .pre, .content = content, .lang = fence_lang });
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

const FenceOpen = struct {
    backtick_count: usize,
    lang: []const u8,
};

/// Classify a line as a fence opening: 3+ backticks, optional info string (no backticks in it).
fn classifyFenceOpen(line: []const u8) ?FenceOpen {
    var count: usize = 0;
    while (count < line.len and line[count] == '`') count += 1;
    if (count < 3) return null;
    const rest = std.mem.trim(u8, line[count..], " \t");
    // Info string must not contain backticks
    if (std.mem.indexOfScalar(u8, rest, '`') != null) return null;
    return .{ .backtick_count = count, .lang = rest };
}

/// A closing fence has >= min_backticks backticks and only optional trailing whitespace.
fn isClosingFence(line: []const u8, min_backticks: usize) bool {
    var count: usize = 0;
    while (count < line.len and line[count] == '`') count += 1;
    if (count < min_backticks) return false;
    for (line[count..]) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

/// A line is blank if it contains only whitespace.
fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Pass 2 — Tree builder + inline parser
// ---------------------------------------------------------------------------

/// Convert a list of Blocks into a ztree Node tree (a fragment of top-level elements).
fn buildTree(allocator: std.mem.Allocator, blocks: []const Block) !Node {
    if (blocks.len == 0) return .{ .fragment = &.{} };

    const nodes = try allocator.alloc(Node, blocks.len);
    for (blocks, 0..) |block, i| {
        if (block.tag == .pre) {
            nodes[i] = try buildCodeBlock(allocator, block);
        } else {
            const children = try parseInlines(allocator, block.content);
            nodes[i] = .{ .element = .{
                .tag = tagName(block.tag),
                .attrs = &.{},
                .children = children,
            } };
        }
    }

    return .{ .fragment = nodes };
}

/// Build a pre>code element, with optional class="language-X" on the code element.
fn buildCodeBlock(allocator: std.mem.Allocator, block: Block) !Node {
    const code_children = try allocator.alloc(Node, 1);
    code_children[0] = .{ .text = block.content };

    const code_attrs: []const ztree.Attr = if (block.lang.len > 0) blk: {
        const prefix = "language-";
        const class_value = try allocator.alloc(u8, prefix.len + block.lang.len);
        @memcpy(class_value[0..prefix.len], prefix);
        @memcpy(class_value[prefix.len..], block.lang);
        const attrs = try allocator.alloc(ztree.Attr, 1);
        attrs[0] = .{ .key = "class", .value = class_value };
        break :blk attrs;
    } else &.{};

    const pre_children = try allocator.alloc(Node, 1);
    pre_children[0] = .{ .element = .{
        .tag = "code",
        .attrs = code_attrs,
        .children = code_children,
    } };

    return .{ .element = .{
        .tag = "pre",
        .attrs = &.{},
        .children = pre_children,
    } };
}

/// Parse inline Markdown within a leaf block's content. Currently handles:
/// - backtick code spans (single or multi-backtick)
/// - plain text (everything else)
fn parseInlines(allocator: std.mem.Allocator, content: []const u8) ![]const Node {
    var nodes: std.ArrayList(Node) = .empty;
    var text_start: usize = 0;
    var pos: usize = 0;

    while (pos < content.len) {
        if (content[pos] == '`') {
            // Count opening backticks
            const open_start = pos;
            while (pos < content.len and content[pos] == '`') pos += 1;
            const open_count = pos - open_start;

            // Find matching closing backticks (same count)
            if (findClosingBackticks(content, pos, open_count)) |close_start| {
                // Flush pending text
                if (text_start < open_start) {
                    try nodes.append(allocator, .{ .text = content[text_start..open_start] });
                }

                // Build code span
                const raw_code = content[pos..close_start];
                const code_children = try allocator.alloc(Node, 1);
                code_children[0] = .{ .text = trimCodeSpan(raw_code) };
                try nodes.append(allocator, .{ .element = .{
                    .tag = "code",
                    .attrs = &.{},
                    .children = code_children,
                } });

                pos = close_start + open_count;
                text_start = pos;
            }
            // No matching close — backticks are literal text, pos already advanced past them.
        } else {
            pos += 1;
        }
    }

    // Flush remaining text
    if (text_start < content.len) {
        try nodes.append(allocator, .{ .text = content[text_start..] });
    }

    return try nodes.toOwnedSlice(allocator);
}

/// Find closing backtick run of exactly `count` length, starting search at `start`.
fn findClosingBackticks(content: []const u8, start: usize, count: usize) ?usize {
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
fn trimCodeSpan(content: []const u8) []const u8 {
    if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ') {
        for (content) |c| {
            if (c != ' ') return content[1 .. content.len - 1];
        }
    }
    return content;
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
        .pre => "pre",
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

// -- helper unit tests: isBlankLine --

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

// -- helper unit tests: classifyHeading --

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

// -- helper unit tests: classifyFenceOpen --

test "classifyFenceOpen — three backticks" {
    const f = classifyFenceOpen("```").?;
    try testing.expectEqual(3, f.backtick_count);
    try testing.expectEqualStrings("", f.lang);
}

test "classifyFenceOpen — with language" {
    const f = classifyFenceOpen("```zig").?;
    try testing.expectEqual(3, f.backtick_count);
    try testing.expectEqualStrings("zig", f.lang);
}

test "classifyFenceOpen — four backticks with language" {
    const f = classifyFenceOpen("````rust").?;
    try testing.expectEqual(4, f.backtick_count);
    try testing.expectEqualStrings("rust", f.lang);
}

test "classifyFenceOpen — two backticks is not a fence" {
    try testing.expectEqual(null, classifyFenceOpen("``"));
}

test "classifyFenceOpen — backticks in info string rejected" {
    try testing.expectEqual(null, classifyFenceOpen("``` foo`bar"));
}

// -- helper unit tests: isClosingFence --

test "isClosingFence — exact match" {
    try testing.expect(isClosingFence("```", 3));
}

test "isClosingFence — more backticks than opening" {
    try testing.expect(isClosingFence("````", 3));
}

test "isClosingFence — with trailing spaces" {
    try testing.expect(isClosingFence("```  ", 3));
}

test "isClosingFence — fewer backticks not a close" {
    try testing.expect(!isClosingFence("``", 3));
}

test "isClosingFence — text after backticks not a close" {
    try testing.expect(!isClosingFence("``` foo", 3));
}

// -- helper unit tests: trimCodeSpan --

test "trimCodeSpan — strips one space from each end" {
    try testing.expectEqualStrings("foo", trimCodeSpan(" foo "));
}

test "trimCodeSpan — no stripping without both spaces" {
    try testing.expectEqualStrings("foo ", trimCodeSpan("foo "));
}

test "trimCodeSpan — all spaces not stripped" {
    try testing.expectEqualStrings("   ", trimCodeSpan("   "));
}

test "trimCodeSpan — empty content unchanged" {
    try testing.expectEqualStrings("", trimCodeSpan(""));
}

// -- helper unit tests: findClosingBackticks --

test "findClosingBackticks — single backtick match" {
    try testing.expectEqual(5, findClosingBackticks("hello`world", 0, 1));
}

test "findClosingBackticks — double backtick match" {
    try testing.expectEqual(5, findClosingBackticks("hello``world", 0, 2));
}

test "findClosingBackticks — no match" {
    try testing.expectEqual(null, findClosingBackticks("hello world", 0, 1));
}

test "findClosingBackticks — skip wrong count" {
    // Looking for single backtick, should skip the double backtick
    try testing.expectEqual(null, findClosingBackticks("hello``world", 0, 1));
}

// -- parse: headings and paragraphs (step 1, unchanged) --

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

// -- zero-copy (step 1) --

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

// -- parse: fenced code blocks --

test "fenced code block — no language" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "```\nhello\n```");
    const nodes = try expectFragment(tree, 1);
    const pre = nodes[0];
    try testing.expectEqualStrings("pre", pre.element.tag);
    const code = pre.element.children[0];
    try testing.expectEqualStrings("code", code.element.tag);
    try testing.expectEqual(0, code.element.attrs.len);
    try testing.expectEqualStrings("hello\n", code.element.children[0].text);
}

test "fenced code block — with language" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "```zig\nconst x = 1;\n```");
    const nodes = try expectFragment(tree, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("code", code.element.tag);
    try testing.expectEqual(1, code.element.attrs.len);
    try testing.expectEqualStrings("class", code.element.attrs[0].key);
    try testing.expectEqualStrings("language-zig", code.element.attrs[0].value.?);
    try testing.expectEqualStrings("const x = 1;\n", code.element.children[0].text);
}

test "fenced code block — multiple lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "```\nline 1\nline 2\n```");
    const nodes = try expectFragment(tree, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("line 1\nline 2\n", code.element.children[0].text);
}

test "fenced code block — empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "```\n```");
    const nodes = try expectFragment(tree, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("", code.element.children[0].text);
}

test "fenced code block — unclosed runs to end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "```\nhello\nworld");
    const nodes = try expectFragment(tree, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("hello\nworld", code.element.children[0].text);
}

test "fenced code block — between paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Before.\n\n```\ncode\n```\n\nAfter.");
    const nodes = try expectFragment(tree, 3);
    try expectTextElement(nodes[0], "p", "Before.");
    try testing.expectEqualStrings("pre", nodes[1].element.tag);
    try expectTextElement(nodes[2], "p", "After.");
}

test "fenced code block — four backticks needs four to close" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "````\n```\nstill code\n````");
    const nodes = try expectFragment(tree, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("```\nstill code\n", code.element.children[0].text);
}

test "fenced code block — headings inside are not parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "```\n# Not a heading\n```");
    const nodes = try expectFragment(tree, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("# Not a heading\n", code.element.children[0].text);
}

test "fenced code block — content is zero-copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "```\nhello\n```";
    const tree = try parse(arena.allocator(), input);
    const text_content = tree.fragment[0].element.children[0].element.children[0].text;
    try testing.expectEqualStrings("hello\n", text_content);
    try testing.expect(text_content.ptr == input.ptr + 4);
}

// -- parse: inline code --

test "inline code in paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Use `foo` here.");
    const nodes = try expectFragment(tree, 1);
    const p = nodes[0];
    try testing.expectEqualStrings("p", p.element.tag);
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("Use ", p.element.children[0].text);
    try testing.expectEqualStrings("code", p.element.children[1].element.tag);
    try testing.expectEqualStrings("foo", p.element.children[1].element.children[0].text);
    try testing.expectEqualStrings(" here.", p.element.children[2].text);
}

test "inline code at start of line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "`code` then text");
    const nodes = try expectFragment(tree, 1);
    const p = nodes[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("code", p.element.children[0].element.tag);
    try testing.expectEqualStrings(" then text", p.element.children[1].text);
}

test "inline code at end of line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "text then `code`");
    const nodes = try expectFragment(tree, 1);
    const p = nodes[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("text then ", p.element.children[0].text);
    try testing.expectEqualStrings("code", p.element.children[1].element.tag);
}

test "multiple inline code spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "`a` and `b`");
    const nodes = try expectFragment(tree, 1);
    const p = nodes[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("code", p.element.children[0].element.tag);
    try testing.expectEqualStrings("a", p.element.children[0].element.children[0].text);
    try testing.expectEqualStrings(" and ", p.element.children[1].text);
    try testing.expectEqualStrings("code", p.element.children[2].element.tag);
    try testing.expectEqualStrings("b", p.element.children[2].element.children[0].text);
}

test "double-backtick inline code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Use ``foo ` bar`` here.");
    const nodes = try expectFragment(tree, 1);
    const p = nodes[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("Use ", p.element.children[0].text);
    try testing.expectEqualStrings("foo ` bar", p.element.children[1].element.children[0].text);
    try testing.expectEqualStrings(" here.", p.element.children[2].text);
}

test "unmatched backtick is literal text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "a ` b");
    const nodes = try expectFragment(tree, 1);
    try expectTextElement(nodes[0], "p", "a ` b");
}

test "inline code in heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "## The `parse` function");
    const nodes = try expectFragment(tree, 1);
    const h = nodes[0];
    try testing.expectEqualStrings("h2", h.element.tag);
    try testing.expectEqual(3, h.element.children.len);
    try testing.expectEqualStrings("The ", h.element.children[0].text);
    try testing.expectEqualStrings("code", h.element.children[1].element.tag);
    try testing.expectEqualStrings("parse", h.element.children[1].element.children[0].text);
    try testing.expectEqualStrings(" function", h.element.children[2].text);
}

test "inline code — space stripping per CommonMark" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "`` ` ``");
    const nodes = try expectFragment(tree, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("code", code.element.tag);
    try testing.expectEqualStrings("`", code.element.children[0].text);
}
