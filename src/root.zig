/// ztree-parse-md — GFM Markdown parser for ztree.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;

const block = @import("block/root.zig");
const tree = @import("tree/root.zig");
const inlines = @import("inlines/root.zig");

// Re-exports used by tests
const isBlankLine = block.isBlankLine;
const isThematicBreak = block.isThematicBreak;
const classifyHeading = block.classifyHeading;
const classifyFenceOpen = block.classifyFenceOpen;
const isClosingFence = block.isClosingFence;
const classifyListItem = block.classifyListItem;
const stripBlockquotePrefix = block.stripBlockquotePrefix;
const isTableSeparator = block.isTableSeparator;
const findClosingBackticks = inlines.findClosingBackticks;
const trimCodeSpan = inlines.trimCodeSpan;
const parseUrlTitle = inlines.parseUrlTitle;

/// Parse Markdown text into a ztree Node tree.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!Node {
    const blocks = try block.parseBlocks(allocator, input);
    return tree.buildTree(allocator, blocks, &parse);
}

// Force sub-module tests to be included
comptime {
    _ = block;
    _ = tree;
    _ = inlines;
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

// -- parse: headings and paragraphs --

test "single heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "# Hello");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "h1", "Hello");
}

test "single paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Hello world");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "Hello world");
}

test "multi-line paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Line one\nLine two");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "Line one\nLine two");
}

test "heading then paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "# Title\n\nSome text.");
    const nodes = try expectFragment(t, 2);
    try expectTextElement(nodes[0], "h1", "Title");
    try expectTextElement(nodes[1], "p", "Some text.");
}

test "two paragraphs separated by blank line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "First.\n\nSecond.");
    const nodes = try expectFragment(t, 2);
    try expectTextElement(nodes[0], "p", "First.");
    try expectTextElement(nodes[1], "p", "Second.");
}

test "multiple blank lines between blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "First.\n\n\n\nSecond.");
    const nodes = try expectFragment(t, 2);
    try expectTextElement(nodes[0], "p", "First.");
    try expectTextElement(nodes[1], "p", "Second.");
}

test "heading between paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Intro.\n\n## Section\n\nBody.");
    const nodes = try expectFragment(t, 3);
    try expectTextElement(nodes[0], "p", "Intro.");
    try expectTextElement(nodes[1], "h2", "Section");
    try expectTextElement(nodes[2], "p", "Body.");
}

test "heading immediately after paragraph (no blank line)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Some text.\n# Heading");
    const nodes = try expectFragment(t, 2);
    try expectTextElement(nodes[0], "p", "Some text.");
    try expectTextElement(nodes[1], "h1", "Heading");
}

test "all heading levels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6");
    const nodes = try expectFragment(t, 6);
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
    const t = try parse(arena.allocator(), "");
    _ = try expectFragment(t, 0);
}

test "only blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "\n\n\n");
    _ = try expectFragment(t, 0);
}

test "trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Hello\n");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "Hello");
}

// -- zero-copy --

test "heading text is zero-copy — points into original input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "# Hello";
    const t = try parse(arena.allocator(), input);
    const text_content = t.fragment[0].element.children[0].text;
    try testing.expectEqualStrings("Hello", text_content);
    try testing.expect(text_content.ptr == input.ptr + 2);
}

test "multi-line paragraph is zero-copy — spans original input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "Line 1\nLine 2";
    const t = try parse(arena.allocator(), input);
    const text_content = t.fragment[0].element.children[0].text;
    try testing.expectEqualStrings("Line 1\nLine 2", text_content);
    try testing.expect(text_content.ptr == input.ptr);
}

// -- parse: fenced code blocks --

test "fenced code block — no language" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "```\nhello\n```");
    const nodes = try expectFragment(t, 1);
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
    const t = try parse(arena.allocator(), "```zig\nconst x = 1;\n```");
    const nodes = try expectFragment(t, 1);
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
    const t = try parse(arena.allocator(), "```\nline 1\nline 2\n```");
    const nodes = try expectFragment(t, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("line 1\nline 2\n", code.element.children[0].text);
}

test "fenced code block — empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "```\n```");
    const nodes = try expectFragment(t, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("", code.element.children[0].text);
}

test "fenced code block — unclosed runs to end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "```\nhello\nworld");
    const nodes = try expectFragment(t, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("hello\nworld", code.element.children[0].text);
}

test "fenced code block — between paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Before.\n\n```\ncode\n```\n\nAfter.");
    const nodes = try expectFragment(t, 3);
    try expectTextElement(nodes[0], "p", "Before.");
    try testing.expectEqualStrings("pre", nodes[1].element.tag);
    try expectTextElement(nodes[2], "p", "After.");
}

test "fenced code block — four backticks needs four to close" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "````\n```\nstill code\n````");
    const nodes = try expectFragment(t, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("```\nstill code\n", code.element.children[0].text);
}

test "fenced code block — headings inside are not parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "```\n# Not a heading\n```");
    const nodes = try expectFragment(t, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("# Not a heading\n", code.element.children[0].text);
}

test "fenced code block — content is zero-copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "```\nhello\n```";
    const t = try parse(arena.allocator(), input);
    const text_content = t.fragment[0].element.children[0].element.children[0].text;
    try testing.expectEqualStrings("hello\n", text_content);
    try testing.expect(text_content.ptr == input.ptr + 4);
}

// -- parse: thematic breaks --

test "thematic break — dashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "---");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("hr", nodes[0].element.tag);
    try testing.expectEqual(0, nodes[0].element.children.len);
}

test "thematic break — asterisks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "***");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("hr", nodes[0].element.tag);
}

test "thematic break — underscores" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "___");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("hr", nodes[0].element.tag);
}

test "thematic break — between paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Above.\n\n---\n\nBelow.");
    const nodes = try expectFragment(t, 3);
    try expectTextElement(nodes[0], "p", "Above.");
    try testing.expectEqualStrings("hr", nodes[1].element.tag);
    try expectTextElement(nodes[2], "p", "Below.");
}

test "thematic break — immediately after paragraph becomes setext h2" {
    // Per CommonMark: --- after a paragraph is a setext heading underline, not a thematic break
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Above.\n---");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "h2", "Above.");
}

test "thematic break — with spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- - -");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("hr", nodes[0].element.tag);
}

// -- parse: blockquotes --

test "simple blockquote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "> Hello");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("blockquote", nodes[0].element.tag);
    const inner = nodes[0].element.children;
    try testing.expectEqual(1, inner.len);
    try expectTextElement(inner[0], "p", "Hello");
}

test "blockquote — multi-line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "> Line 1\n> Line 2");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("blockquote", nodes[0].element.tag);
    const inner = nodes[0].element.children;
    try testing.expectEqual(1, inner.len);
    try expectTextElement(inner[0], "p", "Line 1\nLine 2");
}

test "blockquote — with heading inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "> # Title\n>\n> Body.");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("blockquote", nodes[0].element.tag);
    const inner = nodes[0].element.children;
    try testing.expectEqual(2, inner.len);
    try expectTextElement(inner[0], "h1", "Title");
    try expectTextElement(inner[1], "p", "Body.");
}

test "blockquote — between paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Before.\n\n> Quote.\n\nAfter.");
    const nodes = try expectFragment(t, 3);
    try expectTextElement(nodes[0], "p", "Before.");
    try testing.expectEqualStrings("blockquote", nodes[1].element.tag);
    try expectTextElement(nodes[2], "p", "After.");
}

test "blockquote — nested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "> > Nested");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("blockquote", nodes[0].element.tag);
    const outer = nodes[0].element.children;
    try testing.expectEqual(1, outer.len);
    try testing.expectEqualStrings("blockquote", outer[0].element.tag);
    const inner = outer[0].element.children;
    try testing.expectEqual(1, inner.len);
    try expectTextElement(inner[0], "p", "Nested");
}

test "blockquote — blank line without > ends blockquote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "> First\n\n> Second");
    const nodes = try expectFragment(t, 2);
    try testing.expectEqualStrings("blockquote", nodes[0].element.tag);
    try testing.expectEqualStrings("blockquote", nodes[1].element.tag);
}

test "blockquote — immediately after paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Text.\n> Quote.");
    const nodes = try expectFragment(t, 2);
    try expectTextElement(nodes[0], "p", "Text.");
    try testing.expectEqualStrings("blockquote", nodes[1].element.tag);
}

test "blockquote — with inline code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "> Use `foo` here.");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("blockquote", nodes[0].element.tag);
    const p = nodes[0].element.children[0];
    try testing.expectEqualStrings("p", p.element.tag);
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("Use ", p.element.children[0].text);
    try testing.expectEqualStrings("code", p.element.children[1].element.tag);
    try testing.expectEqualStrings(" here.", p.element.children[2].text);
}

// -- parse: lists --

test "unordered list — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- Alpha\n- Beta\n- Gamma");
    const nodes = try expectFragment(t, 1);
    const ul = nodes[0];
    try testing.expectEqualStrings("ul", ul.element.tag);
    try testing.expectEqual(3, ul.element.children.len);
    try expectTextElement(ul.element.children[0], "li", "Alpha");
    try expectTextElement(ul.element.children[1], "li", "Beta");
    try expectTextElement(ul.element.children[2], "li", "Gamma");
}

test "ordered list — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "1. First\n2. Second");
    const nodes = try expectFragment(t, 1);
    const ol = nodes[0];
    try testing.expectEqualStrings("ol", ol.element.tag);
    try testing.expectEqual(2, ol.element.children.len);
    try expectTextElement(ol.element.children[0], "li", "First");
    try expectTextElement(ol.element.children[1], "li", "Second");
}

test "list — between paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Before.\n\n- A\n- B\n\nAfter.");
    const nodes = try expectFragment(t, 3);
    try expectTextElement(nodes[0], "p", "Before.");
    try testing.expectEqualStrings("ul", nodes[1].element.tag);
    try expectTextElement(nodes[2], "p", "After.");
}

test "list — asterisk marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "* One\n* Two");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("ul", nodes[0].element.tag);
    try testing.expectEqual(2, nodes[0].element.children.len);
}

test "list — mixed types are separate lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- Unordered\n1. Ordered");
    const nodes = try expectFragment(t, 2);
    try testing.expectEqualStrings("ul", nodes[0].element.tag);
    try testing.expectEqualStrings("ol", nodes[1].element.tag);
}

test "list — nested unordered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- Parent\n  - Child 1\n  - Child 2\n- Sibling");
    const nodes = try expectFragment(t, 1);
    const ul = nodes[0];
    try testing.expectEqualStrings("ul", ul.element.tag);
    try testing.expectEqual(2, ul.element.children.len);
    const li1 = ul.element.children[0];
    try testing.expectEqualStrings("li", li1.element.tag);
    try testing.expectEqual(2, li1.element.children.len);
    try testing.expectEqualStrings("Parent", li1.element.children[0].text);
    try testing.expectEqualStrings("ul", li1.element.children[1].element.tag);
    try testing.expectEqual(2, li1.element.children[1].element.children.len);
    try expectTextElement(ul.element.children[1], "li", "Sibling");
}

test "list — nested ordered inside unordered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- Item\n  1. Sub one\n  2. Sub two");
    const nodes = try expectFragment(t, 1);
    const li = nodes[0].element.children[0];
    try testing.expectEqual(2, li.element.children.len);
    try testing.expectEqualStrings("ol", li.element.children[1].element.tag);
}

test "list — task list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- [x] Done\n- [ ] Todo\n- Regular");
    const nodes = try expectFragment(t, 1);
    const ul = nodes[0];
    try testing.expectEqual(3, ul.element.children.len);
    const done = ul.element.children[0];
    try testing.expectEqual(1, done.element.attrs.len);
    try testing.expectEqualStrings("checked", done.element.attrs[0].key);
    try testing.expectEqual(null, done.element.attrs[0].value);
    try testing.expectEqual(0, ul.element.children[1].element.attrs.len);
    try testing.expectEqual(0, ul.element.children[2].element.attrs.len);
}

test "list — with inline code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- Use `foo`");
    const li = t.fragment[0].element.children[0];
    try testing.expectEqual(2, li.element.children.len);
    try testing.expectEqualStrings("Use ", li.element.children[0].text);
    try testing.expectEqualStrings("code", li.element.children[1].element.tag);
}

test "list — single item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- Solo");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("ul", nodes[0].element.tag);
    try testing.expectEqual(1, nodes[0].element.children.len);
}

test "list — immediately after paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Text.\n- Item");
    const nodes = try expectFragment(t, 2);
    try expectTextElement(nodes[0], "p", "Text.");
    try testing.expectEqualStrings("ul", nodes[1].element.tag);
}

// -- parse: emphasis --

test "em — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Hello *world*");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("Hello ", p.element.children[0].text);
    try testing.expectEqualStrings("em", p.element.children[1].element.tag);
    try testing.expectEqualStrings("world", p.element.children[1].element.children[0].text);
}

test "strong — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Hello **world**");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("Hello ", p.element.children[0].text);
    try testing.expectEqualStrings("strong", p.element.children[1].element.tag);
    try testing.expectEqualStrings("world", p.element.children[1].element.children[0].text);
}

test "em+strong — triple stars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "***bold italic***");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(1, p.element.children.len);
    const em = p.element.children[0];
    try testing.expectEqualStrings("em", em.element.tag);
    try testing.expectEqualStrings("strong", em.element.children[0].element.tag);
    try testing.expectEqualStrings("bold italic", em.element.children[0].element.children[0].text);
}

test "strong with em inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "**bold *italic* bold**");
    const p = (try expectFragment(t, 1))[0];
    const strong = p.element.children[0];
    try testing.expectEqualStrings("strong", strong.element.tag);
    try testing.expectEqual(3, strong.element.children.len);
    try testing.expectEqualStrings("bold ", strong.element.children[0].text);
    try testing.expectEqualStrings("em", strong.element.children[1].element.tag);
    try testing.expectEqualStrings("italic", strong.element.children[1].element.children[0].text);
    try testing.expectEqualStrings(" bold", strong.element.children[2].text);
}

test "em with strong inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "*italic **bold** italic*");
    const p = (try expectFragment(t, 1))[0];
    const em = p.element.children[0];
    try testing.expectEqualStrings("em", em.element.tag);
    try testing.expectEqual(3, em.element.children.len);
    try testing.expectEqualStrings("italic ", em.element.children[0].text);
    try testing.expectEqualStrings("strong", em.element.children[1].element.tag);
    try testing.expectEqualStrings("bold", em.element.children[1].element.children[0].text);
    try testing.expectEqualStrings(" italic", em.element.children[2].text);
}

test "em — at start" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "*em* text");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("em", p.element.children[0].element.tag);
    try testing.expectEqualStrings(" text", p.element.children[1].text);
}

test "em — at end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "text *em*");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("text ", p.element.children[0].text);
    try testing.expectEqualStrings("em", p.element.children[1].element.tag);
}

test "unmatched star — literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a * b");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "a * b");
}

test "emphasis with code inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "**the `parse` function**");
    const p = (try expectFragment(t, 1))[0];
    const strong = p.element.children[0];
    try testing.expectEqualStrings("strong", strong.element.tag);
    try testing.expectEqual(3, strong.element.children.len);
    try testing.expectEqualStrings("the ", strong.element.children[0].text);
    try testing.expectEqualStrings("code", strong.element.children[1].element.tag);
    try testing.expectEqualStrings(" function", strong.element.children[2].text);
}

test "emphasis in heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "## A **bold** heading");
    const h = (try expectFragment(t, 1))[0];
    try testing.expectEqualStrings("h2", h.element.tag);
    try testing.expectEqual(3, h.element.children.len);
    try testing.expectEqualStrings("A ", h.element.children[0].text);
    try testing.expectEqualStrings("strong", h.element.children[1].element.tag);
    try testing.expectEqualStrings(" heading", h.element.children[2].text);
}

test "multiple emphasis spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "*a* and *b*");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("em", p.element.children[0].element.tag);
    try testing.expectEqualStrings(" and ", p.element.children[1].text);
    try testing.expectEqualStrings("em", p.element.children[2].element.tag);
}

// -- parse: tables --

test "table — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "| A | B |\n| --- | --- |\n| 1 | 2 |");
    const nodes = try expectFragment(t, 1);
    const table = nodes[0];
    try testing.expectEqualStrings("table", table.element.tag);
    try testing.expectEqual(2, table.element.children.len);
    const thead = table.element.children[0];
    try testing.expectEqualStrings("thead", thead.element.tag);
    const header_row = thead.element.children[0];
    try testing.expectEqualStrings("tr", header_row.element.tag);
    try testing.expectEqual(2, header_row.element.children.len);
    try testing.expectEqualStrings("th", header_row.element.children[0].element.tag);
    try testing.expectEqualStrings("A", header_row.element.children[0].element.children[0].text);
    try testing.expectEqualStrings("th", header_row.element.children[1].element.tag);
    try testing.expectEqualStrings("B", header_row.element.children[1].element.children[0].text);
    const tbody = table.element.children[1];
    try testing.expectEqualStrings("tbody", tbody.element.tag);
    const body_row = tbody.element.children[0];
    try testing.expectEqualStrings("tr", body_row.element.tag);
    try testing.expectEqual(2, body_row.element.children.len);
    try testing.expectEqualStrings("td", body_row.element.children[0].element.tag);
    try testing.expectEqualStrings("1", body_row.element.children[0].element.children[0].text);
    try testing.expectEqualStrings("td", body_row.element.children[1].element.tag);
    try testing.expectEqualStrings("2", body_row.element.children[1].element.children[0].text);
}

test "table — multiple body rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "| H |\n| --- |\n| r1 |\n| r2 |\n| r3 |");
    const table = (try expectFragment(t, 1))[0];
    const tbody = table.element.children[1];
    try testing.expectEqual(3, tbody.element.children.len);
    try testing.expectEqualStrings("r1", tbody.element.children[0].element.children[0].element.children[0].text);
    try testing.expectEqualStrings("r2", tbody.element.children[1].element.children[0].element.children[0].text);
    try testing.expectEqualStrings("r3", tbody.element.children[2].element.children[0].element.children[0].text);
}

test "table — alignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "| L | C | R | N |\n| :--- | :---: | ---: | --- |\n| a | b | c | d |");
    const table = (try expectFragment(t, 1))[0];
    const ths = table.element.children[0].element.children[0].element.children;
    try testing.expectEqual(1, ths[0].element.attrs.len);
    try testing.expectEqualStrings("text-align: left", ths[0].element.attrs[0].value.?);
    try testing.expectEqual(1, ths[1].element.attrs.len);
    try testing.expectEqualStrings("text-align: center", ths[1].element.attrs[0].value.?);
    try testing.expectEqual(1, ths[2].element.attrs.len);
    try testing.expectEqualStrings("text-align: right", ths[2].element.attrs[0].value.?);
    try testing.expectEqual(0, ths[3].element.attrs.len);
    const tds = table.element.children[1].element.children[0].element.children;
    try testing.expectEqualStrings("text-align: left", tds[0].element.attrs[0].value.?);
    try testing.expectEqualStrings("text-align: center", tds[1].element.attrs[0].value.?);
    try testing.expectEqualStrings("text-align: right", tds[2].element.attrs[0].value.?);
    try testing.expectEqual(0, tds[3].element.attrs.len);
}

test "table — header only (no body)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "| H1 | H2 |\n| --- | --- |");
    const table = (try expectFragment(t, 1))[0];
    try testing.expectEqualStrings("table", table.element.tag);
    try testing.expectEqual(1, table.element.children.len);
    try testing.expectEqualStrings("thead", table.element.children[0].element.tag);
}

test "table — inline formatting in cells" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "| Name |\n| --- |\n| **bold** |");
    const td = (try expectFragment(t, 1))[0].element.children[1].element.children[0].element.children[0];
    try testing.expectEqualStrings("td", td.element.tag);
    try testing.expectEqualStrings("strong", td.element.children[0].element.tag);
}

test "table — followed by paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "| A |\n| --- |\n| 1 |\n\nAfter table.");
    const nodes = try expectFragment(t, 2);
    try testing.expectEqualStrings("table", nodes[0].element.tag);
    try expectTextElement(nodes[1], "p", "After table.");
}

test "table — preceded by paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Before.\n\n| A |\n| --- |\n| 1 |");
    const nodes = try expectFragment(t, 2);
    try expectTextElement(nodes[0], "p", "Before.");
    try testing.expectEqualStrings("table", nodes[1].element.tag);
}

test "table — not a table without separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "| just a line |");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("p", nodes[0].element.tag);
}

// -- parse: strikethrough --

test "strikethrough — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Hello ~~world~~");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("Hello ", p.element.children[0].text);
    try testing.expectEqualStrings("del", p.element.children[1].element.tag);
    try testing.expectEqualStrings("world", p.element.children[1].element.children[0].text);
}

test "strikethrough — with emphasis inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "~~**bold** strike~~");
    const p = (try expectFragment(t, 1))[0];
    const del = p.element.children[0];
    try testing.expectEqualStrings("del", del.element.tag);
    try testing.expectEqual(2, del.element.children.len);
    try testing.expectEqualStrings("strong", del.element.children[0].element.tag);
    try testing.expectEqualStrings(" strike", del.element.children[1].text);
}

test "strikethrough — unmatched is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a ~~ b");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "a ~~ b");
}

test "strikethrough — single tilde is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a ~b~ c");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "a ~b~ c");
}

test "strikethrough — multiple spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "~~a~~ and ~~b~~");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("del", p.element.children[0].element.tag);
    try testing.expectEqualStrings(" and ", p.element.children[1].text);
    try testing.expectEqualStrings("del", p.element.children[2].element.tag);
}

// -- parse: line breaks --

test "hard break — two trailing spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "line1  \nline2");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("line1", p.element.children[0].text);
    try testing.expectEqualStrings("br", p.element.children[1].element.tag);
    try testing.expectEqual(0, p.element.children[1].element.children.len);
    try testing.expectEqualStrings("line2", p.element.children[2].text);
}

test "hard break — backslash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "line1\\\nline2");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("line1", p.element.children[0].text);
    try testing.expectEqualStrings("br", p.element.children[1].element.tag);
    try testing.expectEqualStrings("line2", p.element.children[2].text);
}

test "soft break — no br element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "line1\nline2");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(1, p.element.children.len);
    try testing.expectEqualStrings("line1\nline2", p.element.children[0].text);
}

test "hard break — multiple trailing spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "line1     \nline2");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("line1", p.element.children[0].text);
    try testing.expectEqualStrings("br", p.element.children[1].element.tag);
    try testing.expectEqualStrings("line2", p.element.children[2].text);
}

test "hard break — with emphasis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "*em*  \ntext");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("em", p.element.children[0].element.tag);
    try testing.expectEqualStrings("br", p.element.children[1].element.tag);
    try testing.expectEqualStrings("text", p.element.children[2].text);
}

// -- parse: links and images --

test "link — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[click](https://example.com)");
    const p = (try expectFragment(t, 1))[0];
    const a = p.element.children[0];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqual(1, a.element.attrs.len);
    try testing.expectEqualStrings("href", a.element.attrs[0].key);
    try testing.expectEqualStrings("https://example.com", a.element.attrs[0].value.?);
    try testing.expectEqualStrings("click", a.element.children[0].text);
}

test "link — with title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[click](url \"My Title\")");
    const a = (try expectFragment(t, 1))[0].element.children[0];
    try testing.expectEqual(2, a.element.attrs.len);
    try testing.expectEqualStrings("href", a.element.attrs[0].key);
    try testing.expectEqualStrings("url", a.element.attrs[0].value.?);
    try testing.expectEqualStrings("title", a.element.attrs[1].key);
    try testing.expectEqualStrings("My Title", a.element.attrs[1].value.?);
}

test "link — with emphasis inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[**bold** link](url)");
    const a = (try expectFragment(t, 1))[0].element.children[0];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqual(2, a.element.children.len);
    try testing.expectEqualStrings("strong", a.element.children[0].element.tag);
    try testing.expectEqualStrings(" link", a.element.children[1].text);
}

test "link — surrounded by text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "See [here](url) for details.");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("See ", p.element.children[0].text);
    try testing.expectEqualStrings("a", p.element.children[1].element.tag);
    try testing.expectEqualStrings(" for details.", p.element.children[2].text);
}

test "image — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "![photo](img.jpg)");
    const p = (try expectFragment(t, 1))[0];
    const img = p.element.children[0];
    try testing.expectEqualStrings("img", img.element.tag);
    try testing.expectEqual(2, img.element.attrs.len);
    try testing.expectEqualStrings("src", img.element.attrs[0].key);
    try testing.expectEqualStrings("img.jpg", img.element.attrs[0].value.?);
    try testing.expectEqualStrings("alt", img.element.attrs[1].key);
    try testing.expectEqualStrings("photo", img.element.attrs[1].value.?);
    try testing.expectEqual(0, img.element.children.len);
}

test "image — with title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "![alt](src \"My Photo\")");
    const img = (try expectFragment(t, 1))[0].element.children[0];
    try testing.expectEqual(3, img.element.attrs.len);
    try testing.expectEqualStrings("title", img.element.attrs[2].key);
    try testing.expectEqualStrings("My Photo", img.element.attrs[2].value.?);
}

test "image — surrounded by text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Before ![pic](x.png) after.");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("Before ", p.element.children[0].text);
    try testing.expectEqualStrings("img", p.element.children[1].element.tag);
    try testing.expectEqualStrings(" after.", p.element.children[2].text);
}

test "link — unmatched bracket is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "just [text here");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "just [text here");
}

test "link — bracket without paren is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[text] no link");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "[text] no link");
}

test "link — URL with balanced parens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[wiki](https://en.wikipedia.org/wiki/Foo_(bar))");
    const a = (try expectFragment(t, 1))[0].element.children[0];
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Foo_(bar)", a.element.attrs[0].value.?);
}

test "multiple links in one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[a](1) and [b](2)");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("a", p.element.children[0].element.tag);
    try testing.expectEqualStrings(" and ", p.element.children[1].text);
    try testing.expectEqualStrings("a", p.element.children[2].element.tag);
}

// -- parse: extended autolinks --

test "bare URL — https" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Visit https://example.com today.");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("Visit ", p.element.children[0].text);
    const a = p.element.children[1];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqualStrings("https://example.com", a.element.attrs[0].value.?);
    try testing.expectEqualStrings("https://example.com", a.element.children[0].text);
    try testing.expectEqualStrings(" today.", p.element.children[2].text);
}

test "bare URL — http" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "See http://example.com for more.");
    const a = (try expectFragment(t, 1))[0].element.children[1];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqualStrings("http://example.com", a.element.attrs[0].value.?);
}

test "bare URL — trailing punctuation stripped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "See https://example.com.");
    const p = (try expectFragment(t, 1))[0];
    const a = p.element.children[1];
    try testing.expectEqualStrings("https://example.com", a.element.attrs[0].value.?);
    try testing.expectEqualStrings(".", p.element.children[2].text);
}

test "bare URL — not just h" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "hello world");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "hello world");
}

// -- parse: inline HTML --

test "inline HTML — simple tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Hello <em>world</em>.");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(5, p.element.children.len);
    try testing.expectEqualStrings("Hello ", p.element.children[0].text);
    try testing.expectEqualStrings("<em>", p.element.children[1].raw);
    try testing.expectEqualStrings("world", p.element.children[2].text);
    try testing.expectEqualStrings("</em>", p.element.children[3].raw);
    try testing.expectEqualStrings(".", p.element.children[4].text);
}

test "inline HTML — self-closing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Line<br/>break.");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("<br/>", p.element.children[1].raw);
}

test "inline HTML — with attributes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "A <span class=\"x\">B</span> C");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqualStrings("<span class=\"x\">", p.element.children[1].raw);
}

test "inline HTML — comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Before <!-- comment --> after.");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("<!-- comment -->", p.element.children[1].raw);
}

// -- parse: block HTML --

test "HTML block — div" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "<div class=\"note\">\nHello\n</div>");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("<div class=\"note\">\nHello\n</div>", nodes[0].raw);
}

test "HTML block — not rendered as paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Text.\n\n<section>\nContent\n</section>\n\nMore text.");
    const nodes = try expectFragment(t, 3);
    try expectTextElement(nodes[0], "p", "Text.");
    try testing.expectEqualStrings("<section>\nContent\n</section>", nodes[1].raw);
    try expectTextElement(nodes[2], "p", "More text.");
}

// -- parse: loose lists --

test "loose list — blank between items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- one\n\n- two\n\n- three");
    const nodes = try expectFragment(t, 1);
    const ul = nodes[0];
    try testing.expectEqualStrings("ul", ul.element.tag);
    try testing.expectEqual(3, ul.element.children.len);
    // Loose list: each li wraps content in p
    const li1 = ul.element.children[0];
    try testing.expectEqualStrings("li", li1.element.tag);
    try testing.expectEqual(1, li1.element.children.len);
    try testing.expectEqualStrings("p", li1.element.children[0].element.tag);
    try testing.expectEqualStrings("one", li1.element.children[0].element.children[0].text);
}

test "tight list — no blank between items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- one\n- two\n- three");
    const nodes = try expectFragment(t, 1);
    const ul = nodes[0];
    const li1 = ul.element.children[0];
    // Tight list: content directly in li, no p wrapping
    try testing.expectEqualStrings("one", li1.element.children[0].text);
}

// -- parse: multi-paragraph list items --

test "multi-paragraph list item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "- First para.\n\n  Second para.");
    const nodes = try expectFragment(t, 1);
    const li = nodes[0].element.children[0];
    try testing.expectEqualStrings("li", li.element.tag);
    // Should have two p children
    try testing.expectEqual(2, li.element.children.len);
    try testing.expectEqualStrings("p", li.element.children[0].element.tag);
    try testing.expectEqualStrings("First para.", li.element.children[0].element.children[0].text);
    try testing.expectEqualStrings("p", li.element.children[1].element.tag);
    try testing.expectEqualStrings("Second para.", li.element.children[1].element.children[0].text);
}

// -- parse: entity references --

test "entity — named &amp;" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "A &amp; B");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("A ", p.element.children[0].text);
    try testing.expectEqualStrings("&", p.element.children[1].text);
    try testing.expectEqualStrings(" B", p.element.children[2].text);
}

test "entity — named &lt; &gt;" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "&lt;div&gt;");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("<", p.element.children[0].text);
    try testing.expectEqualStrings("div", p.element.children[1].text);
    try testing.expectEqualStrings(">", p.element.children[2].text);
}

test "entity — numeric decimal &#38;" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "&#38;");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqualStrings("&", p.element.children[0].text);
}

test "entity — numeric hex &#x26;" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "&#x26;");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqualStrings("&", p.element.children[0].text);
}

test "entity — &quot;" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "&quot;hello&quot;");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("\"", p.element.children[0].text);
    try testing.expectEqualStrings("hello", p.element.children[1].text);
    try testing.expectEqualStrings("\"", p.element.children[2].text);
}

test "entity — unknown is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "&unknown;");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "&unknown;");
}

test "entity — no semicolon is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a &amp b");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "a &amp b");
}

// -- parse: intra-word underscore --

test "underscore — intra-word not emphasis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "foo_bar_baz");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "foo_bar_baz");
}

test "underscore — double intra-word not emphasis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "foo__bar__baz");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "foo__bar__baz");
}

test "underscore — at word boundary still works" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "_italic_ text");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("em", p.element.children[0].element.tag);
}

test "star — intra-word still works" {
    // Stars work intra-word per CommonMark
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "foo*bar*baz");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("foo", p.element.children[0].text);
    try testing.expectEqualStrings("em", p.element.children[1].element.tag);
    try testing.expectEqualStrings("baz", p.element.children[2].text);
}

// -- parse: nested mixed emphasis --

test "nested emphasis — em wrapping strong" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "*foo **bar** baz*");
    const p = (try expectFragment(t, 1))[0];
    const em = p.element.children[0];
    try testing.expectEqualStrings("em", em.element.tag);
    try testing.expectEqual(3, em.element.children.len);
    try testing.expectEqualStrings("foo ", em.element.children[0].text);
    try testing.expectEqualStrings("strong", em.element.children[1].element.tag);
    try testing.expectEqualStrings("bar", em.element.children[1].element.children[0].text);
    try testing.expectEqualStrings(" baz", em.element.children[2].text);
}

test "nested emphasis — strong wrapping em" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "**foo *bar* baz**");
    const p = (try expectFragment(t, 1))[0];
    const strong = p.element.children[0];
    try testing.expectEqualStrings("strong", strong.element.tag);
    try testing.expectEqual(3, strong.element.children.len);
    try testing.expectEqualStrings("foo ", strong.element.children[0].text);
    try testing.expectEqualStrings("em", strong.element.children[1].element.tag);
    try testing.expectEqualStrings(" baz", strong.element.children[2].text);
}

// -- parse: setext headings --

test "setext h1 — equals underline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Heading One\n===");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "h1", "Heading One");
}

test "setext h2 — dashes underline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Heading Two\n---");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "h2", "Heading Two");
}

test "setext h1 — long underline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Title\n==========");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "h1", "Title");
}

test "setext — with inline formatting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Hello **world**\n===");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("h1", nodes[0].element.tag);
    try testing.expectEqual(2, nodes[0].element.children.len);
    try testing.expectEqualStrings("Hello ", nodes[0].element.children[0].text);
    try testing.expectEqualStrings("strong", nodes[0].element.children[1].element.tag);
}

test "setext — standalone --- is thematic break" {
    // --- without a preceding paragraph is a thematic break
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Above.\n\n---");
    const nodes = try expectFragment(t, 2);
    try expectTextElement(nodes[0], "p", "Above.");
    try testing.expectEqualStrings("hr", nodes[1].element.tag);
}

test "setext — after blank line is thematic break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "---");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("hr", nodes[0].element.tag);
}

// -- parse: indented code blocks --

test "indented code — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "    code line");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("pre", nodes[0].element.tag);
    const code_el = nodes[0].element.children[0];
    try testing.expectEqualStrings("code", code_el.element.tag);
    try testing.expectEqualStrings("code line", code_el.element.children[0].text);
}

test "indented code — multiple lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "    line 1\n    line 2\n    line 3");
    const nodes = try expectFragment(t, 1);
    const code_el = nodes[0].element.children[0];
    try testing.expectEqualStrings("code", code_el.element.tag);
    try testing.expectEqualStrings("line 1\nline 2\nline 3", code_el.element.children[0].text);
}

test "indented code — with blank line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "    line 1\n\n    line 2");
    const nodes = try expectFragment(t, 1);
    const code_el = nodes[0].element.children[0];
    try testing.expectEqualStrings("line 1\n\nline 2", code_el.element.children[0].text);
}

test "indented code — not in paragraph" {
    // Text followed by indented code (with blank line separation)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Text.\n\n    code");
    const nodes = try expectFragment(t, 2);
    try expectTextElement(nodes[0], "p", "Text.");
    try testing.expectEqualStrings("pre", nodes[1].element.tag);
}

test "indented code — no lang attribute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "    x = 1");
    const pre = (try expectFragment(t, 1))[0];
    // Indented code has no language, just pre > code > text
    try testing.expectEqualStrings("pre", pre.element.tag);
    const code_el = pre.element.children[0];
    try testing.expectEqual(0, code_el.element.attrs.len);
}

test "indented code — trailing blank lines stripped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "    code\n\n\nAfter.");
    const nodes = try expectFragment(t, 2);
    const code_el = nodes[0].element.children[0];
    try testing.expectEqualStrings("code", code_el.element.children[0].text);
    try expectTextElement(nodes[1], "p", "After.");
}

// -- parse: reference links --

test "reflink — full reference [text][ref]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Click [here][link].\n\n[link]: https://example.com");
    const nodes = try expectFragment(t, 1);
    const p = nodes[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("Click ", p.element.children[0].text);
    const a = p.element.children[1];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqualStrings("https://example.com", a.element.attrs[0].value.?);
    try testing.expectEqualStrings("here", a.element.children[0].text);
    try testing.expectEqualStrings(".", p.element.children[2].text);
}

test "reflink — collapsed reference [text][]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Visit [example][].\n\n[example]: https://example.com");
    const a = (try expectFragment(t, 1))[0].element.children[1];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqualStrings("https://example.com", a.element.attrs[0].value.?);
    try testing.expectEqualStrings("example", a.element.children[0].text);
}

test "reflink — shortcut reference [text]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "See [example].\n\n[example]: https://example.com");
    const a = (try expectFragment(t, 1))[0].element.children[1];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqualStrings("https://example.com", a.element.attrs[0].value.?);
}

test "reflink — case insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[Link][FOO]\n\n[foo]: https://example.com");
    const a = (try expectFragment(t, 1))[0].element.children[0];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqualStrings("https://example.com", a.element.attrs[0].value.?);
}

test "reflink — with title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[text][ref]\n\n[ref]: url \"My Title\"");
    const a = (try expectFragment(t, 1))[0].element.children[0];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqual(2, a.element.attrs.len);
    try testing.expectEqualStrings("My Title", a.element.attrs[1].value.?);
}

test "reflink — image reference ![alt][ref]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "![photo][img]\n\n[img]: pic.jpg \"Photo\"");
    const img = (try expectFragment(t, 1))[0].element.children[0];
    try testing.expectEqualStrings("img", img.element.tag);
    try testing.expectEqualStrings("pic.jpg", img.element.attrs[0].value.?);
    try testing.expectEqualStrings("photo", img.element.attrs[1].value.?);
    try testing.expectEqualStrings("Photo", img.element.attrs[2].value.?);
}

test "reflink — undefined ref is literal text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[text][missing]");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "[text][missing]");
}

test "reflink — definition not rendered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[ref]: https://example.com\n\nA paragraph.");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("p", nodes[0].element.tag);
    try testing.expectEqualStrings("A paragraph.", nodes[0].element.children[0].text);
}

test "reflink — multiple definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[a][1] and [b][2]\n\n[1]: url1\n[2]: url2");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("url1", p.element.children[0].element.attrs[0].value.?);
    try testing.expectEqualStrings("url2", p.element.children[2].element.attrs[0].value.?);
}

// -- parse: footnotes --

test "footnote — reference produces sup > a" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Text[^1] here.\n\n[^1]: The footnote.");
    const nodes = try expectFragment(t, 2); // paragraph + section
    const p = nodes[0];
    try testing.expectEqualStrings("p", p.element.tag);
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("Text", p.element.children[0].text);
    // sup > a
    const sup = p.element.children[1];
    try testing.expectEqualStrings("sup", sup.element.tag);
    const a = sup.element.children[0];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqualStrings("#fn-1", a.element.attrs[0].value.?);
    try testing.expectEqualStrings("fnref-1", a.element.attrs[1].value.?);
    try testing.expectEqualStrings("1", a.element.children[0].text);
    try testing.expectEqualStrings(" here.", p.element.children[2].text);
}

test "footnote — section at end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Text[^1].\n\n[^1]: Note content.");
    const nodes = try expectFragment(t, 2);
    const section = nodes[1];
    try testing.expectEqualStrings("section", section.element.tag);
    try testing.expectEqualStrings("class", section.element.attrs[0].key);
    try testing.expectEqualStrings("footnotes", section.element.attrs[0].value.?);
    // section > ol > li
    const ol = section.element.children[0];
    try testing.expectEqualStrings("ol", ol.element.tag);
    const li = ol.element.children[0];
    try testing.expectEqualStrings("li", li.element.tag);
    try testing.expectEqualStrings("id", li.element.attrs[0].key);
    try testing.expectEqualStrings("fn-1", li.element.attrs[0].value.?);
    // li content + backref
    try testing.expectEqualStrings("Note content.", li.element.children[0].text);
    try testing.expectEqualStrings(" ", li.element.children[1].text);
    const backref = li.element.children[2];
    try testing.expectEqualStrings("a", backref.element.tag);
    try testing.expectEqualStrings("#fnref-1", backref.element.attrs[0].value.?);
    try testing.expectEqualStrings("↩", backref.element.children[0].text);
}

test "footnote — multiple footnotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "A[^1] and B[^note].\n\n[^1]: First.\n[^note]: Second.");
    const nodes = try expectFragment(t, 2);
    const ol = nodes[1].element.children[0];
    try testing.expectEqual(2, ol.element.children.len);
    try testing.expectEqualStrings("fn-1", ol.element.children[0].element.attrs[0].value.?);
    try testing.expectEqualStrings("fn-note", ol.element.children[1].element.attrs[0].value.?);
}

test "footnote — named label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "See[^ref].\n\n[^ref]: Details here.");
    const nodes = try expectFragment(t, 2);
    const sup = nodes[0].element.children[1];
    try testing.expectEqualStrings("ref", sup.element.children[0].element.children[0].text);
}

test "footnote — no definitions means no section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Just a paragraph.");
    const nodes = try expectFragment(t, 1);
    try testing.expectEqualStrings("p", nodes[0].element.tag);
}

test "footnote — inline formatting in definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Text[^1].\n\n[^1]: A **bold** note.");
    const li = (try expectFragment(t, 2))[1].element.children[0].element.children[0];
    try testing.expectEqualStrings("A ", li.element.children[0].text);
    try testing.expectEqualStrings("strong", li.element.children[1].element.tag);
}

// -- parse: escape sequences --

test "escape — star not emphasis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "\\*not italic\\*");
    const p = (try expectFragment(t, 1))[0];
    // Produces: "*not italic" then "*" (backslashes stripped, stars literal)
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("*not italic", p.element.children[0].text);
    try testing.expectEqualStrings("*", p.element.children[1].text);
}

test "escape — backslash before bracket" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "\\[not a link\\]");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("[not a link", p.element.children[0].text);
    try testing.expectEqualStrings("]", p.element.children[1].text);
}

test "escape — tilde not strikethrough" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "\\~\\~not deleted\\~\\~");
    const p = (try expectFragment(t, 1))[0];
    // Each \~ produces a segment break: "~" "~not deleted" "~" "~"
    try testing.expectEqual(4, p.element.children.len);
    try testing.expectEqualStrings("~", p.element.children[0].text);
    try testing.expectEqualStrings("~not deleted", p.element.children[1].text);
}

test "escape — backslash before non-punctuation is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "\\n is not an escape");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "\\n is not an escape");
}

test "escape — double backslash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "\\\\visible backslash");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(1, p.element.children.len);
    try testing.expectEqualStrings("\\visible backslash", p.element.children[0].text);
}

// -- parse: underscore emphasis --

test "em — underscore" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Hello _world_");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("Hello ", p.element.children[0].text);
    try testing.expectEqualStrings("em", p.element.children[1].element.tag);
    try testing.expectEqualStrings("world", p.element.children[1].element.children[0].text);
}

test "strong — underscore" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Hello __world__");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("Hello ", p.element.children[0].text);
    try testing.expectEqualStrings("strong", p.element.children[1].element.tag);
    try testing.expectEqualStrings("world", p.element.children[1].element.children[0].text);
}

test "em+strong — triple underscore" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "___bold italic___");
    const p = (try expectFragment(t, 1))[0];
    const em = p.element.children[0];
    try testing.expectEqualStrings("em", em.element.tag);
    try testing.expectEqualStrings("strong", em.element.children[0].element.tag);
    try testing.expectEqualStrings("bold italic", em.element.children[0].element.children[0].text);
}

test "mixed star and underscore emphasis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "*star* and _under_");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("em", p.element.children[0].element.tag);
    try testing.expectEqualStrings(" and ", p.element.children[1].text);
    try testing.expectEqualStrings("em", p.element.children[2].element.tag);
}

// -- parse: autolinks --

test "autolink — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Visit <https://example.com> now.");
    const p = (try expectFragment(t, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("Visit ", p.element.children[0].text);
    const a = p.element.children[1];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqualStrings("href", a.element.attrs[0].key);
    try testing.expectEqualStrings("https://example.com", a.element.attrs[0].value.?);
    try testing.expectEqualStrings("https://example.com", a.element.children[0].text);
    try testing.expectEqualStrings(" now.", p.element.children[2].text);
}

test "autolink — not without scheme" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "<not-a-link>");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "<not-a-link>");
}

test "autolink — ftp scheme" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "<ftp://files.example.com>");
    const a = (try expectFragment(t, 1))[0].element.children[0];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqualStrings("ftp://files.example.com", a.element.attrs[0].value.?);
}

test "autolink — no spaces allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "<https://not a link>");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "<https://not a link>");
}

// -- parse: inline code --

test "inline code in paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "Use `foo` here.");
    const nodes = try expectFragment(t, 1);
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
    const t = try parse(arena.allocator(), "`code` then text");
    const nodes = try expectFragment(t, 1);
    const p = nodes[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("code", p.element.children[0].element.tag);
    try testing.expectEqualStrings(" then text", p.element.children[1].text);
}

test "inline code at end of line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "text then `code`");
    const nodes = try expectFragment(t, 1);
    const p = nodes[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("text then ", p.element.children[0].text);
    try testing.expectEqualStrings("code", p.element.children[1].element.tag);
}

test "multiple inline code spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "`a` and `b`");
    const nodes = try expectFragment(t, 1);
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
    const t = try parse(arena.allocator(), "Use ``foo ` bar`` here.");
    const nodes = try expectFragment(t, 1);
    const p = nodes[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("Use ", p.element.children[0].text);
    try testing.expectEqualStrings("foo ` bar", p.element.children[1].element.children[0].text);
    try testing.expectEqualStrings(" here.", p.element.children[2].text);
}

test "unmatched backtick is literal text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a ` b");
    const nodes = try expectFragment(t, 1);
    try expectTextElement(nodes[0], "p", "a ` b");
}

test "inline code in heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "## The `parse` function");
    const nodes = try expectFragment(t, 1);
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
    const t = try parse(arena.allocator(), "`` ` ``");
    const nodes = try expectFragment(t, 1);
    const code = nodes[0].element.children[0];
    try testing.expectEqualStrings("code", code.element.tag);
    try testing.expectEqualStrings("`", code.element.children[0].text);
}
