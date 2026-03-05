/// SAX-to-tree adapter: builds a ztree Node tree from bun-md's
/// enter/leave/text event stream.
const std = @import("std");
const ztree = @import("ztree");
const md = @import("bun-md");

const Node = ztree.Node;
const Allocator = std.mem.Allocator;
const TreeBuilder = ztree.TreeBuilder;
const BlockType = md.BlockType;
const SpanType = md.SpanType;
const TextType = md.TextType;
const SpanDetail = md.SpanDetail;

// ─── Public API ────────────────────────────────────────────────────────────

pub fn parse(allocator: Allocator, input: []const u8) !Node {
    const src = skipBom(input);
    var b = Adapter.init(allocator, src);
    md.renderWithRenderer(input, allocator, .{}, .{
        .ptr = @ptrCast(&b),
        .vtable = &Adapter.vtable,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StackOverflow => return error.StackOverflow,
        error.JSError, error.JSTerminated => unreachable,
    };
    return b.finish();
}

fn skipBom(s: []const u8) []const u8 {
    return if (s.len >= 3 and s[0] == 0xEF and s[1] == 0xBB and s[2] == 0xBF) s[3..] else s;
}

// ─── Adapter ───────────────────────────────────────────────────────────────

const Adapter = struct {
    builder: TreeBuilder,
    alloc: Allocator,
    src: []const u8,

    const vtable = md.Renderer.VTable{
        .enterBlock = onEnterBlock,
        .leaveBlock = onLeaveBlock,
        .enterSpan = onEnterSpan,
        .leaveSpan = onLeaveSpan,
        .text = onText,
    };

    fn init(alloc: Allocator, src: []const u8) Adapter {
        return .{ .builder = TreeBuilder.init(alloc), .alloc = alloc, .src = src };
    }

    fn finish(self: *Adapter) !Node {
        return self.builder.finish() catch |err| switch (err) {
            error.UnclosedElement => {
                // Silently close unclosed elements (parser guarantees balance,
                // but be defensive). Force-drain the stack.
                while (self.builder.depth() > 0) {
                    self.builder.close() catch break;
                }
                return self.builder.finish() catch return .{ .fragment = &.{} };
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    // ── Helpers ────────────────────────────────────────────────────────

    fn dupe(self: *Adapter, s: []const u8) []const u8 {
        return self.alloc.dupe(u8, s) catch "";
    }

    const h_tags = [_][]const u8{ "h1", "h1", "h2", "h3", "h4", "h5", "h6" };

    fn headingTag(level: u32) []const u8 {
        return if (level >= 1 and level <= 6) h_tags[level] else "h6";
    }

    fn extractLang(self: *Adapter, offset: u32) []const u8 {
        var end: usize = offset;
        while (end < self.src.len and self.src[end] != ' ' and
            self.src[end] != '\t' and self.src[end] != '\n' and self.src[end] != '\r')
            end += 1;
        return if (end > offset) self.src[offset..end] else "";
    }

    // ── Block events ───────────────────────────────────────────────────

    fn onEnterBlock(ptr: *anyopaque, block_type: BlockType, data: u32, flags: u32) error{}!void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        var b = &self.builder;
        switch (block_type) {
            .doc, .html => {},
            .quote => b.open("blockquote", .{}) catch {},
            .ul => b.open("ul", .{}) catch {},
            .p => b.open("p", .{}) catch {},
            .table => b.open("table", .{}) catch {},
            .thead => b.open("thead", .{}) catch {},
            .tbody => b.open("tbody", .{}) catch {},
            .tr => b.open("tr", .{}) catch {},
            .h => b.open(headingTag(data), .{}) catch {},
            .hr => b.closedElement("hr", .{}) catch {},
            .ol => {
                if (data == 1) {
                    b.open("ol", .{}) catch {};
                } else {
                    const s = std.fmt.allocPrint(self.alloc, "{d}", .{data}) catch "";
                    b.open("ol", self.alloc.dupe(ztree.Attr, &.{.{ .key = "start", .value = s }}) catch &.{}) catch {};
                }
            },
            .li => {
                b.open("li", .{}) catch {};
                const mark = md.types.taskMarkFromData(data);
                if (mark != 0) {
                    if (md.types.isTaskChecked(mark)) {
                        b.closedElement("input", self.alloc.dupe(ztree.Attr, &.{
                            .{ .key = "type", .value = "checkbox" },
                            .{ .key = "checked", .value = null },
                        }) catch &.{}) catch {};
                    } else {
                        b.closedElement("input", self.alloc.dupe(ztree.Attr, &.{
                            .{ .key = "type", .value = "checkbox" },
                        }) catch &.{}) catch {};
                    }
                }
            },
            .code => {
                b.open("pre", .{}) catch {};
                if (flags & md.BLOCK_FENCED_CODE != 0 and data < self.src.len) {
                    const lang = self.extractLang(data);
                    if (lang.len > 0) {
                        const cls = std.fmt.allocPrint(self.alloc, "language-{s}", .{lang}) catch "";
                        b.open("code", self.alloc.dupe(ztree.Attr, &.{.{ .key = "class", .value = cls }}) catch &.{}) catch {};
                    } else {
                        b.open("code", .{}) catch {};
                    }
                } else {
                    b.open("code", .{}) catch {};
                }
            },
            .th, .td => {
                const tag: []const u8 = if (block_type == .th) "th" else "td";
                if (md.types.alignmentName(md.types.alignmentFromData(data))) |name| {
                    const val = std.fmt.allocPrint(self.alloc, "text-align: {s}", .{name}) catch "";
                    b.open(tag, self.alloc.dupe(ztree.Attr, &.{.{ .key = "style", .value = val }}) catch &.{}) catch {};
                } else {
                    b.open(tag, .{}) catch {};
                }
            },
        }
    }

    fn onLeaveBlock(ptr: *anyopaque, block_type: BlockType, _: u32) error{}!void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        var b = &self.builder;
        switch (block_type) {
            .doc, .hr, .html => {},
            .code => { b.close() catch {}; b.close() catch {}; }, // code + pre
            else => b.close() catch {},
        }
    }

    // ── Span events ────────────────────────────────────────────────────

    fn onEnterSpan(ptr: *anyopaque, span_type: SpanType, detail: SpanDetail) error{}!void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        var b = &self.builder;
        switch (span_type) {
            .em => b.open("em", .{}) catch {},
            .strong => b.open("strong", .{}) catch {},
            .u => b.open("u", .{}) catch {},
            .code => b.open("code", .{}) catch {},
            .del => b.open("del", .{}) catch {},
            .latexmath, .latexmath_display => b.open("x-equation", .{}) catch {},
            .a, .wikilink => {
                const href = self.dupe(detail.href);
                b.open("a", self.alloc.dupe(ztree.Attr, &.{.{ .key = "href", .value = href }}) catch &.{}) catch {};
            },
            .img => {
                const src_val = self.dupe(detail.href);
                b.open("img", self.alloc.dupe(ztree.Attr, &.{.{ .key = "src", .value = src_val }}) catch &.{}) catch {};
            },
        }
    }

    fn onLeaveSpan(ptr: *anyopaque, span_type: SpanType) error{}!void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        var b = &self.builder;
        if (span_type == .img) {
            // Images: pop the frame, collect alt text from children,
            // then emit a closed <img src="..." alt="..."> element.
            const f = b.popRaw() catch return;
            const src_val = for (f.attrs) |a| {
                if (std.mem.eql(u8, a.key, "src")) break a.value orelse "";
            } else "";
            const alt = collectText(self.alloc, f.children);
            b.closedElement("img", self.alloc.dupe(ztree.Attr, &.{
                .{ .key = "src", .value = src_val },
                .{ .key = "alt", .value = alt },
            }) catch &.{}) catch {};
        } else b.close() catch {};
    }

    // ── Text events ────────────────────────────────────────────────────

    fn onText(ptr: *anyopaque, text_type: TextType, content: []const u8) error{}!void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        var b = &self.builder;
        switch (text_type) {
            .normal, .code, .entity, .latexmath => {
                const owned = self.alloc.dupe(u8, content) catch return;
                b.text(owned) catch {};
            },
            .html => {
                const owned = self.alloc.dupe(u8, content) catch return;
                b.raw(owned) catch {};
            },
            .null_char => {
                const owned = self.alloc.dupe(u8, "\u{FFFD}") catch return;
                b.text(owned) catch {};
            },
            .br => b.closedElement("br", .{}) catch {},
            .softbr => {
                const owned = self.alloc.dupe(u8, "\n") catch return;
                b.text(owned) catch {};
            },
        }
    }
};

// ─── Helpers ───────────────────────────────────────────────────────────────

fn collectText(allocator: Allocator, nodes: []const Node) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    collectInto(&buf, allocator, nodes);
    return buf.toOwnedSlice(allocator) catch "";
}

fn collectInto(buf: *std.ArrayList(u8), alloc: Allocator, nodes: []const Node) void {
    for (nodes) |n| switch (n) {
        .text => |t| buf.appendSlice(alloc, t) catch {},
        .raw => |r| buf.appendSlice(alloc, r) catch {},
        .element => |el| collectInto(buf, alloc, el.children),
        .fragment => |ch| collectInto(buf, alloc, ch),
    };
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectElement(node: Node, expected_tag: []const u8) ![]const Node {
    try testing.expectEqual(.element, std.meta.activeTag(node));
    try testing.expectEqualStrings(expected_tag, node.element.tag);
    return node.element.children;
}

fn expectText(node: Node, expected: []const u8) !void {
    try testing.expectEqual(.text, std.meta.activeTag(node));
    try testing.expectEqualStrings(expected, node.text);
}

fn expectAttr(node: Node, key: []const u8) ?[]const u8 {
    if (std.meta.activeTag(node) != .element) return null;
    for (node.element.attrs) |a| {
        if (std.mem.eql(u8, a.key, key)) return a.value;
    }
    return null;
}

test "heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "# Hello");
    const ch = try expectElement(node, "h1");
    try expectText(ch[0], "Hello");
}

test "heading levels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "## Two\n### Three\n#### Four");
    try testing.expectEqual(.fragment, std.meta.activeTag(node));
    _ = try expectElement(node.fragment[0], "h2");
    _ = try expectElement(node.fragment[1], "h3");
    _ = try expectElement(node.fragment[2], "h4");
}

test "paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "Hello world");
    const ch = try expectElement(node, "p");
    try expectText(ch[0], "Hello world");
}

test "blockquote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "> Quote");
    const bq = try expectElement(node, "blockquote");
    const p = try expectElement(bq[0], "p");
    try expectText(p[0], "Quote");
}

test "thematic break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "---");
    try testing.expectEqualStrings("hr", node.element.tag);
    try testing.expectEqual(0, node.element.children.len);
}

test "fenced code block with language" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "```zig\nconst x = 1;\n```");
    const pre = try expectElement(node, "pre");
    _ = try expectElement(pre[0], "code");
    try testing.expectEqualStrings("language-zig", expectAttr(pre[0], "class").?);
    try testing.expect(pre[0].element.children.len >= 1);
}

test "fenced code block without language" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "```\nhello\n```");
    const pre = try expectElement(node, "pre");
    _ = try expectElement(pre[0], "code");
}

test "unordered list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "- one\n- two");
    const ul = try expectElement(node, "ul");
    try testing.expectEqual(2, ul.len);
    const li1 = try expectElement(ul[0], "li");
    try expectText(li1[0], "one");
}

test "ordered list with start" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "3. foo\n4. bar");
    try testing.expectEqualStrings("ol", node.element.tag);
    try testing.expectEqualStrings("3", expectAttr(node, "start").?);
}

test "table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "| a | b |\n| - | - |\n| 1 | 2 |");
    const table = try expectElement(node, "table");
    _ = try expectElement(table[0], "thead");
    _ = try expectElement(table[1], "tbody");
}

test "emphasis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "*hello*");
    const p = try expectElement(node, "p");
    const em = try expectElement(p[0], "em");
    try expectText(em[0], "hello");
}

test "strong" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "**hello**");
    const p = try expectElement(node, "p");
    const strong = try expectElement(p[0], "strong");
    try expectText(strong[0], "hello");
}

test "strikethrough" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "~~hello~~");
    const p = try expectElement(node, "p");
    const del = try expectElement(p[0], "del");
    try expectText(del[0], "hello");
}

test "link" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "[text](/url)");
    const p = try expectElement(node, "p");
    const a = try expectElement(p[0], "a");
    try testing.expectEqualStrings("/url", expectAttr(p[0], "href").?);
    try expectText(a[0], "text");
}

test "image" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "![alt text](/img.png)");
    const p = try expectElement(node, "p");
    const img = p[0];
    try testing.expectEqualStrings("img", img.element.tag);
    try testing.expectEqualStrings("/img.png", expectAttr(img, "src").?);
    try testing.expectEqualStrings("alt text", expectAttr(img, "alt").?);
}

test "inline code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "`code`");
    const p = try expectElement(node, "p");
    const code = try expectElement(p[0], "code");
    try expectText(code[0], "code");
}

test "hard break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "foo  \nbar");
    const p = try expectElement(node, "p");
    try expectText(p[0], "foo");
    try testing.expectEqualStrings("br", p[1].element.tag);
    try expectText(p[2], "bar");
}

test "reference link" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "[foo][1]\n\n[1]: /url");
    const p = try expectElement(node, "p");
    const a = try expectElement(p[0], "a");
    try testing.expectEqualStrings("/url", expectAttr(p[0], "href").?);
    try expectText(a[0], "foo");
}

test "backslash escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "\\*literal\\*");
    const p = try expectElement(node, "p");
    const full = collectText(arena.allocator(), p);
    try testing.expectEqualStrings("*literal*", full);
}

test "html block passthrough" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "<div>\nhello\n</div>");
    switch (node) {
        .raw => {},
        .fragment => |ch| {
            try testing.expect(ch.len > 0);
            try testing.expectEqual(.raw, std.meta.activeTag(ch[0]));
        },
        else => return error.TestExpectedEqual,
    }
}

test "setext heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "Hello\n=====");
    _ = try expectElement(node, "h1");
}

test "lazy blockquote continuation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "> foo\nbar");
    const bq = try expectElement(node, "blockquote");
    const p = try expectElement(bq[0], "p");
    try testing.expect(p.len >= 1);
}

test "empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "");
    try testing.expectEqual(.fragment, std.meta.activeTag(node));
    try testing.expectEqual(0, node.fragment.len);
}
