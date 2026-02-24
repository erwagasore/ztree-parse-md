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

// ─── Public API ────────────────────────────────────────────────────────────

pub fn parse(allocator: Allocator, input: []const u8) error{ OutOfMemory, StackOverflow }!Node {
    // Skip UTF-8 BOM to match what the parser sees internally
    const src = if (input.len >= 3 and input[0] == 0xEF and input[1] == 0xBB and input[2] == 0xBF)
        input[3..]
    else
        input;

    var builder = TreeBuilder.init(allocator, src);

    const renderer = md.Renderer{
        .ptr = @ptrCast(&builder),
        .vtable = &TreeBuilder.vtable,
    };

    md.renderWithRenderer(input, allocator, .{}, renderer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StackOverflow => return error.StackOverflow,
        error.JSError, error.JSTerminated => unreachable,
    };

    return builder.finish();
}

// ─── Tree builder ──────────────────────────────────────────────────────────

const Frame = struct {
    tag: []const u8,
    attrs: []const ztree.Attr,
    children: std.array_list.Managed(Node),
};

const TreeBuilder = struct {
    allocator: Allocator,
    stack: std.array_list.Managed(Frame),
    src_text: []const u8,

    const vtable = md.Renderer.VTable{
        .enterBlock = enterBlockImpl,
        .leaveBlock = leaveBlockImpl,
        .enterSpan = enterSpanImpl,
        .leaveSpan = leaveSpanImpl,
        .text = textImpl,
    };

    fn init(allocator: Allocator, src_text: []const u8) TreeBuilder {
        var stack = std.array_list.Managed(Frame).init(allocator);
        // Push root frame
        stack.append(.{
            .tag = "",
            .attrs = &.{},
            .children = std.array_list.Managed(Node).init(allocator),
        }) catch {};
        return .{ .allocator = allocator, .stack = stack, .src_text = src_text };
    }

    fn finish(self: *TreeBuilder) Node {
        var root = &self.stack.items[0];
        const children = root.children.toOwnedSlice() catch &.{};
        if (children.len == 1) return children[0];
        return .{ .fragment = children };
    }

    fn current(self: *TreeBuilder) *Frame {
        return &self.stack.items[self.stack.items.len - 1];
    }

    fn pushFrame(self: *TreeBuilder, tag: []const u8, attrs: []const ztree.Attr) void {
        self.stack.append(.{
            .tag = tag,
            .attrs = attrs,
            .children = std.array_list.Managed(Node).init(self.allocator),
        }) catch {};
    }

    fn popFrame(self: *TreeBuilder) void {
        var frame = self.stack.pop() orelse return;
        const children = frame.children.toOwnedSlice() catch &.{};
        const node = Node{ .element = .{
            .tag = frame.tag,
            .attrs = frame.attrs,
            .children = children,
        } };
        self.current().children.append(node) catch {};
    }

    fn appendText(self: *TreeBuilder, content: []const u8) void {
        const owned = self.allocator.alloc(u8, content.len) catch return;
        @memcpy(owned, content);
        self.current().children.append(.{ .text = owned }) catch {};
    }

    fn appendRaw(self: *TreeBuilder, content: []const u8) void {
        const owned = self.allocator.alloc(u8, content.len) catch return;
        @memcpy(owned, content);
        self.current().children.append(.{ .raw = owned }) catch {};
    }

    fn appendVoidElement(self: *TreeBuilder, tag: []const u8, attrs: []const ztree.Attr) void {
        self.current().children.append(ztree.closedElement(tag, attrs)) catch {};
    }

    fn dupeStr(self: *TreeBuilder, s: []const u8) []const u8 {
        return self.allocator.dupe(u8, s) catch "";
    }

    fn makeAttrs(self: *TreeBuilder, comptime n: usize) []ztree.Attr {
        return self.allocator.alloc(ztree.Attr, n) catch return &.{};
    }

    // ── Block events ───────────────────────────────────────────────────

    fn enterBlockImpl(ptr: *anyopaque, block_type: BlockType, data: u32, flags: u32) error{}!void {
        const self: *TreeBuilder = @ptrCast(@alignCast(ptr));
        switch (block_type) {
            .doc => {},
            .quote => self.pushFrame("blockquote", &.{}),
            .ul => self.pushFrame("ul", &.{}),
            .ol => {
                if (data == 1) {
                    self.pushFrame("ol", &.{});
                } else {
                    const start_str = std.fmt.allocPrint(self.allocator, "{d}", .{data}) catch "";
                    const attrs = self.makeAttrs(1);
                    if (attrs.len > 0) attrs[0] = .{ .key = "start", .value = start_str };
                    self.pushFrame("ol", attrs);
                }
            },
            .li => {
                const task_mark = md.types.taskMarkFromData(data);
                self.pushFrame("li", &.{});
                if (task_mark != 0) {
                    if (md.types.isTaskChecked(task_mark)) {
                        const attrs = self.makeAttrs(2);
                        if (attrs.len >= 2) {
                            attrs[0] = .{ .key = "type", .value = "checkbox" };
                            attrs[1] = .{ .key = "checked", .value = null };
                        }
                        self.appendVoidElement("input", attrs);
                    } else {
                        const attrs = self.makeAttrs(1);
                        if (attrs.len > 0) attrs[0] = .{ .key = "type", .value = "checkbox" };
                        self.appendVoidElement("input", attrs);
                    }
                }
            },
            .hr => self.appendVoidElement("hr", &.{}),
            .h => {
                const tag: []const u8 = switch (data) {
                    1 => "h1",
                    2 => "h2",
                    3 => "h3",
                    4 => "h4",
                    5 => "h5",
                    else => "h6",
                };
                self.pushFrame(tag, &.{});
            },
            .code => {
                self.pushFrame("pre", &.{});
                if (flags & md.BLOCK_FENCED_CODE != 0 and data < self.src_text.len) {
                    var lang_end: usize = data;
                    while (lang_end < self.src_text.len and
                        !isBlank(self.src_text[lang_end]) and
                        !isNewline(self.src_text[lang_end]))
                    {
                        lang_end += 1;
                    }
                    if (lang_end > data) {
                        const class_val = std.fmt.allocPrint(self.allocator, "language-{s}", .{self.src_text[data..lang_end]}) catch "";
                        const attrs = self.makeAttrs(1);
                        if (attrs.len > 0) attrs[0] = .{ .key = "class", .value = class_val };
                        self.pushFrame("code", attrs);
                    } else {
                        self.pushFrame("code", &.{});
                    }
                } else {
                    self.pushFrame("code", &.{});
                }
            },
            .html => {},
            .p => self.pushFrame("p", &.{}),
            .table => self.pushFrame("table", &.{}),
            .thead => self.pushFrame("thead", &.{}),
            .tbody => self.pushFrame("tbody", &.{}),
            .tr => self.pushFrame("tr", &.{}),
            .th, .td => {
                const tag: []const u8 = if (block_type == .th) "th" else "td";
                const alignment = md.types.alignmentFromData(data);
                if (md.types.alignmentName(alignment)) |name| {
                    const val = std.fmt.allocPrint(self.allocator, "text-align: {s}", .{name}) catch "";
                    const attrs = self.makeAttrs(1);
                    if (attrs.len > 0) attrs[0] = .{ .key = "style", .value = val };
                    self.pushFrame(tag, attrs);
                } else {
                    self.pushFrame(tag, &.{});
                }
            },
        }
    }

    fn leaveBlockImpl(ptr: *anyopaque, block_type: BlockType, _: u32) error{}!void {
        const self: *TreeBuilder = @ptrCast(@alignCast(ptr));
        switch (block_type) {
            .doc, .hr, .html => {},
            .code => {
                // Pop <code>, then pop <pre>
                self.popFrame(); // code
                self.popFrame(); // pre
            },
            else => self.popFrame(),
        }
    }

    // ── Span events ────────────────────────────────────────────────────

    fn enterSpanImpl(ptr: *anyopaque, span_type: SpanType, detail: SpanDetail) error{}!void {
        const self: *TreeBuilder = @ptrCast(@alignCast(ptr));
        switch (span_type) {
            .em => self.pushFrame("em", &.{}),
            .strong => self.pushFrame("strong", &.{}),
            .u => self.pushFrame("u", &.{}),
            .code => self.pushFrame("code", &.{}),
            .del => self.pushFrame("del", &.{}),
            .latexmath, .latexmath_display => self.pushFrame("x-equation", &.{}),
            .a => {
                const href = self.dupeStr(detail.href);
                const attrs = self.makeAttrs(1);
                if (attrs.len > 0) attrs[0] = .{ .key = "href", .value = href };
                self.pushFrame("a", attrs);
            },
            .img => {
                const src = self.dupeStr(detail.href);
                const attrs = self.makeAttrs(1);
                if (attrs.len > 0) attrs[0] = .{ .key = "src", .value = src };
                self.pushFrame("img", attrs);
            },
            .wikilink => {
                const href = self.dupeStr(detail.href);
                const attrs = self.makeAttrs(1);
                if (attrs.len > 0) attrs[0] = .{ .key = "href", .value = href };
                self.pushFrame("a", attrs);
            },
        }
    }

    fn leaveSpanImpl(ptr: *anyopaque, span_type: SpanType) error{}!void {
        const self: *TreeBuilder = @ptrCast(@alignCast(ptr));
        switch (span_type) {
            .img => {
                var frame = self.stack.pop() orelse return;
                const alt = collectText(self.allocator, frame.children.items);
                const src_val = if (frame.attrs.len > 0) frame.attrs[0].value else null;
                const attrs = self.makeAttrs(2);
                if (attrs.len >= 2) {
                    attrs[0] = .{ .key = "src", .value = src_val orelse "" };
                    attrs[1] = .{ .key = "alt", .value = alt };
                }
                self.appendVoidElement("img", attrs);
            },
            else => self.popFrame(),
        }
    }

    // ── Text events ────────────────────────────────────────────────────

    fn textImpl(ptr: *anyopaque, text_type: TextType, content: []const u8) error{}!void {
        const self: *TreeBuilder = @ptrCast(@alignCast(ptr));
        switch (text_type) {
            .normal, .code, .latexmath => self.appendText(content),
            .html => self.appendRaw(content),
            .entity => self.appendText(content),
            .null_char => self.appendText("\u{FFFD}"),
            .br => self.appendVoidElement("br", &.{}),
            .softbr => self.appendText("\n"),
        }
    }
};

// ─── Helpers ───────────────────────────────────────────────────────────────

fn collectText(allocator: Allocator, nodes: []const Node) []const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    collectTextInto(&buf, nodes);
    return buf.toOwnedSlice() catch "";
}

fn collectTextInto(buf: *std.array_list.Managed(u8), nodes: []const Node) void {
    for (nodes) |node| {
        switch (node) {
            .text => |t| buf.appendSlice(t) catch {},
            .raw => |r| buf.appendSlice(r) catch {},
            .element => |el| collectTextInto(buf, el.children),
            .fragment => |children| collectTextInto(buf, children),
        }
    }
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isNewline(c: u8) bool {
    return c == '\n' or c == '\r';
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

// -- Block tests --

test "heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "# Hello");
    const children = try expectElement(node, "h1");
    try expectText(children[0], "Hello");
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
    const children = try expectElement(node, "p");
    try expectText(children[0], "Hello world");
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
    // Code content is emitted as multiple text events (content + newlines)
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

// -- Inline tests --

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
    // Escaped characters are emitted as separate text events
    // Collect all text content from children
    const full = collectText(arena.allocator(), p);
    try testing.expectEqualStrings("*literal*", full);
}

test "html block passthrough" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "<div>\nhello\n</div>");
    // HTML blocks produce raw nodes (possibly multiple, wrapped in fragment)
    switch (node) {
        .raw => {},
        .fragment => |children| {
            try testing.expect(children.len > 0);
            try testing.expectEqual(.raw, std.meta.activeTag(children[0]));
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
    // Lazy continuation: "bar" is part of the blockquote paragraph
    try testing.expect(p.len >= 1);
}

test "empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "");
    // Empty document produces empty fragment
    try testing.expectEqual(.fragment, std.meta.activeTag(node));
    try testing.expectEqual(0, node.fragment.len);
}
