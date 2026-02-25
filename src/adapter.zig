/// SAX-to-tree adapter: builds a ztree Node tree from bun-md's
/// enter/leave/text event stream.
const std = @import("std");
const ztree = @import("ztree");
const md = @import("bun-md");

const Node = ztree.Node;
const Allocator = std.mem.Allocator;
const BlockType = md.BlockType;
const SpanType = md.SpanType;
const TextType = md.TextType;
const SpanDetail = md.SpanDetail;
const ManagedNodeList = std.array_list.Managed(Node);

// ─── Public API ────────────────────────────────────────────────────────────

pub fn parse(allocator: Allocator, input: []const u8) error{ OutOfMemory, StackOverflow }!Node {
    const src = skipBom(input);
    var b = TreeBuilder.init(allocator, src);
    md.renderWithRenderer(input, allocator, .{}, .{
        .ptr = @ptrCast(&b),
        .vtable = &TreeBuilder.vtable,
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

// ─── Tree builder ──────────────────────────────────────────────────────────

const Frame = struct {
    tag: []const u8,
    attrs: []const ztree.Attr,
    children: ManagedNodeList,
};

const TreeBuilder = struct {
    alloc: Allocator,
    stack: std.array_list.Managed(Frame),
    src: []const u8,

    const vtable = md.Renderer.VTable{
        .enterBlock = onEnterBlock,
        .leaveBlock = onLeaveBlock,
        .enterSpan = onEnterSpan,
        .leaveSpan = onLeaveSpan,
        .text = onText,
    };

    fn init(alloc: Allocator, src: []const u8) TreeBuilder {
        var stack = std.array_list.Managed(Frame).init(alloc);
        stack.append(.{ .tag = "", .attrs = &.{}, .children = ManagedNodeList.init(alloc) }) catch {};
        return .{ .alloc = alloc, .stack = stack, .src = src };
    }

    fn finish(self: *TreeBuilder) Node {
        var root = &self.stack.items[0];
        const children = root.children.toOwnedSlice() catch &.{};
        return if (children.len == 1) children[0] else .{ .fragment = children };
    }

    // ── Stack operations ───────────────────────────────────────────────

    fn top(self: *TreeBuilder) *Frame {
        return &self.stack.items[self.stack.items.len - 1];
    }

    fn push(self: *TreeBuilder, tag: []const u8, attrs: []const ztree.Attr) void {
        self.stack.append(.{ .tag = tag, .attrs = attrs, .children = ManagedNodeList.init(self.alloc) }) catch {};
    }

    fn pop(self: *TreeBuilder) void {
        var f = self.stack.pop() orelse return;
        const children = f.children.toOwnedSlice() catch &.{};
        self.emit(.{ .element = .{ .tag = f.tag, .attrs = f.attrs, .children = children } });
    }

    fn emit(self: *TreeBuilder, node: Node) void {
        self.top().children.append(node) catch {};
    }

    // ── Helpers ────────────────────────────────────────────────────────

    fn dupe(self: *TreeBuilder, s: []const u8) []const u8 {
        return self.alloc.dupe(u8, s) catch "";
    }

    fn copyNode(self: *TreeBuilder, content: []const u8, comptime tag: enum { text, raw }) void {
        const owned = self.alloc.alloc(u8, content.len) catch return;
        @memcpy(owned, content);
        self.emit(if (tag == .text) .{ .text = owned } else .{ .raw = owned });
    }

    fn attr1(self: *TreeBuilder, key: []const u8, value: ?[]const u8) []const ztree.Attr {
        const a = self.alloc.alloc(ztree.Attr, 1) catch return &.{};
        a[0] = .{ .key = key, .value = value };
        return a;
    }

    fn attr2(self: *TreeBuilder, k1: []const u8, v1: ?[]const u8, k2: []const u8, v2: ?[]const u8) []const ztree.Attr {
        const a = self.alloc.alloc(ztree.Attr, 2) catch return &.{};
        a[0] = .{ .key = k1, .value = v1 };
        a[1] = .{ .key = k2, .value = v2 };
        return a;
    }

    fn pushWith(self: *TreeBuilder, tag: []const u8, key: []const u8, value: []const u8) void {
        self.push(tag, self.attr1(key, self.dupe(value)));
    }

    const h_tags = [_][]const u8{ "h1", "h1", "h2", "h3", "h4", "h5", "h6" };

    fn headingTag(level: u32) []const u8 {
        return if (level >= 1 and level <= 6) h_tags[level] else "h6";
    }

    // ── Block events ───────────────────────────────────────────────────

    fn onEnterBlock(ptr: *anyopaque, block_type: BlockType, data: u32, flags: u32) error{}!void {
        const self: *TreeBuilder = @ptrCast(@alignCast(ptr));
        switch (block_type) {
            .doc, .html => {},
            .quote => self.push("blockquote", &.{}),
            .ul => self.push("ul", &.{}),
            .p => self.push("p", &.{}),
            .table => self.push("table", &.{}),
            .thead => self.push("thead", &.{}),
            .tbody => self.push("tbody", &.{}),
            .tr => self.push("tr", &.{}),
            .h => self.push(headingTag(data), &.{}),
            .hr => self.emit(ztree.closedElement("hr", &.{})),
            .ol => {
                if (data == 1) {
                    self.push("ol", &.{});
                } else {
                    const s = std.fmt.allocPrint(self.alloc, "{d}", .{data}) catch "";
                    self.push("ol", self.attr1("start", s));
                }
            },
            .li => {
                self.push("li", &.{});
                const mark = md.types.taskMarkFromData(data);
                if (mark != 0) {
                    if (md.types.isTaskChecked(mark)) {
                        self.emit(ztree.closedElement("input", self.attr2("type", "checkbox", "checked", null)));
                    } else {
                        self.emit(ztree.closedElement("input", self.attr1("type", "checkbox")));
                    }
                }
            },
            .code => {
                self.push("pre", &.{});
                if (flags & md.BLOCK_FENCED_CODE != 0 and data < self.src.len) {
                    const lang = self.extractLang(data);
                    if (lang.len > 0) {
                        const cls = std.fmt.allocPrint(self.alloc, "language-{s}", .{lang}) catch "";
                        self.push("code", self.attr1("class", cls));
                    } else {
                        self.push("code", &.{});
                    }
                } else {
                    self.push("code", &.{});
                }
            },
            .th, .td => {
                const tag: []const u8 = if (block_type == .th) "th" else "td";
                if (md.types.alignmentName(md.types.alignmentFromData(data))) |name| {
                    const val = std.fmt.allocPrint(self.alloc, "text-align: {s}", .{name}) catch "";
                    self.push(tag, self.attr1("style", val));
                } else {
                    self.push(tag, &.{});
                }
            },
        }
    }

    fn onLeaveBlock(ptr: *anyopaque, block_type: BlockType, _: u32) error{}!void {
        const self: *TreeBuilder = @ptrCast(@alignCast(ptr));
        switch (block_type) {
            .doc, .hr, .html => {},
            .code => { self.pop(); self.pop(); }, // code + pre
            else => self.pop(),
        }
    }

    fn extractLang(self: *TreeBuilder, offset: u32) []const u8 {
        var end: usize = offset;
        while (end < self.src.len and self.src[end] != ' ' and
            self.src[end] != '\t' and self.src[end] != '\n' and self.src[end] != '\r')
            end += 1;
        return if (end > offset) self.src[offset..end] else "";
    }

    // ── Span events ────────────────────────────────────────────────────

    fn onEnterSpan(ptr: *anyopaque, span_type: SpanType, detail: SpanDetail) error{}!void {
        const self: *TreeBuilder = @ptrCast(@alignCast(ptr));
        switch (span_type) {
            .em => self.push("em", &.{}),
            .strong => self.push("strong", &.{}),
            .u => self.push("u", &.{}),
            .code => self.push("code", &.{}),
            .del => self.push("del", &.{}),
            .latexmath, .latexmath_display => self.push("x-equation", &.{}),
            .a, .wikilink => self.pushWith("a", "href", detail.href),
            .img => self.pushWith("img", "src", detail.href),
        }
    }

    fn onLeaveSpan(ptr: *anyopaque, span_type: SpanType) error{}!void {
        const self: *TreeBuilder = @ptrCast(@alignCast(ptr));
        if (span_type == .img) {
            var f = self.stack.pop() orelse return;
            const alt = collectText(self.alloc, f.children.items);
            const src_val = if (f.attrs.len > 0) f.attrs[0].value orelse "" else "";
            self.emit(ztree.closedElement("img", self.attr2("src", src_val, "alt", alt)));
        } else self.pop();
    }

    // ── Text events ────────────────────────────────────────────────────

    fn onText(ptr: *anyopaque, text_type: TextType, content: []const u8) error{}!void {
        const self: *TreeBuilder = @ptrCast(@alignCast(ptr));
        switch (text_type) {
            .normal, .code, .entity, .latexmath => self.copyNode(content, .text),
            .html => self.copyNode(content, .raw),
            .null_char => self.copyNode("\u{FFFD}", .text),
            .br => self.emit(ztree.closedElement("br", &.{})),
            .softbr => self.copyNode("\n", .text),
        }
    }
};

// ─── Helpers ───────────────────────────────────────────────────────────────

fn collectText(allocator: Allocator, nodes: []const Node) []const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    collectInto(&buf, nodes);
    return buf.toOwnedSlice() catch "";
}

fn collectInto(buf: *std.array_list.Managed(u8), nodes: []const Node) void {
    for (nodes) |n| switch (n) {
        .text => |t| buf.appendSlice(t) catch {},
        .raw => |r| buf.appendSlice(r) catch {},
        .element => |el| collectInto(buf, el.children),
        .fragment => |ch| collectInto(buf, ch),
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
