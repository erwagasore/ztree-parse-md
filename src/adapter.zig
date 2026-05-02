/// SAX-to-tree adapter: builds a ztree Node tree from bun-md's
/// enter/leave/text event stream.
const std = @import("std");
const ztree = @import("ztree");
const md = @import("bun-md");

const Node = ztree.Node;
const Allocator = std.mem.Allocator;
const TreeBuilder = ztree.TreeBuilder;
const attr = ztree.attr;
const BlockType = md.BlockType;
const SpanType = md.SpanType;
const TextType = md.TextType;
const SpanDetail = md.SpanDetail;

// ─── Public API ────────────────────────────────────────────────────────────

pub const ParseError = error{
    OutOfMemory,
    StackOverflow,
    InvalidMarkdownTree,
};

pub fn parse(arena: Allocator, input: []const u8) ParseError!Node {
    const src = skipBom(input);
    var b = Adapter.init(arena, src);
    defer b.deinit();

    md.renderWithRenderer(src, arena, .{}, .{
        .ptr = @ptrCast(&b),
        .vtable = &Adapter.vtable,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StackOverflow => return error.StackOverflow,
        error.JSError, error.JSTerminated => return error.InvalidMarkdownTree,
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

    fn deinit(self: *Adapter) void {
        self.builder.deinit();
    }

    fn finish(self: *Adapter) ParseError!Node {
        return self.builder.finish() catch |err| switch (err) {
            error.UnclosedElement => return error.InvalidMarkdownTree,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    // ── Helpers ────────────────────────────────────────────────────────

    const CallbackError = error{ JSError, JSTerminated, OutOfMemory };

    fn dupe(self: *Adapter, s: []const u8) CallbackError![]const u8 {
        return self.alloc.dupe(u8, s) catch return error.OutOfMemory;
    }

    fn fmt(self: *Adapter, comptime format: []const u8, args: anytype) CallbackError![]const u8 {
        return std.fmt.allocPrint(self.alloc, format, args) catch return error.OutOfMemory;
    }

    fn hrefValue(self: *Adapter, detail: SpanDetail) CallbackError![]const u8 {
        if (detail.autolink_email) return self.fmt("mailto:{s}", .{detail.href});
        if (detail.autolink_www) return self.fmt("http://{s}", .{detail.href});
        return self.dupe(detail.href);
    }

    fn optionalTitle(self: *Adapter, detail: SpanDetail) CallbackError!?[]const u8 {
        return if (detail.title.len > 0) try self.dupe(detail.title) else null;
    }

    fn closeBuilder(b: *TreeBuilder) CallbackError!void {
        b.close() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ExtraClose => return error.JSError,
        };
    }

    fn popRawBuilder(b: *TreeBuilder) CallbackError!TreeBuilder.PopResult {
        return b.popRaw() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ExtraClose => return error.JSError,
        };
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

    fn onEnterBlock(ptr: *anyopaque, block_type: BlockType, data: u32, flags: u32) CallbackError!void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        const b = &self.builder;
        switch (block_type) {
            .doc, .html => {},
            .quote => try b.open("blockquote", .{}),
            .ul => try b.open("ul", .{}),
            .p => try b.open("p", .{}),
            .table => try b.open("table", .{}),
            .thead => try b.open("thead", .{}),
            .tbody => try b.open("tbody", .{}),
            .tr => try b.open("tr", .{}),
            .h => try b.open(headingTag(data), .{}),
            .hr => try b.closedElement("hr", .{}),
            .ol => {
                if (data == 1) {
                    try b.open("ol", .{});
                } else {
                    const s = try self.fmt("{d}", .{data});
                    try b.open("ol", .{attr("start", s)});
                }
            },
            .li => {
                try b.open("li", .{});
                const mark = md.types.taskMarkFromData(data);
                if (mark != 0) {
                    const checked = md.types.isTaskChecked(mark);
                    try b.closedElement("input", .{
                        attr("type", "checkbox"),
                        if (checked) attr("checked", null) else null,
                    });
                }
            },
            .code => {
                try b.open("pre", .{});
                if (flags & md.BLOCK_FENCED_CODE != 0 and data < self.src.len) {
                    const lang = self.extractLang(data);
                    if (lang.len > 0) {
                        const cls = try self.fmt("language-{s}", .{lang});
                        try b.open("code", .{attr("class", cls)});
                    } else {
                        try b.open("code", .{});
                    }
                } else {
                    try b.open("code", .{});
                }
            },
            .th, .td => {
                const tag: []const u8 = if (block_type == .th) "th" else "td";
                if (md.types.alignmentName(md.types.alignmentFromData(data))) |name| {
                    const val = try self.fmt("text-align: {s}", .{name});
                    try b.open(tag, .{attr("style", val)});
                } else {
                    try b.open(tag, .{});
                }
            },
        }
    }

    fn onLeaveBlock(ptr: *anyopaque, block_type: BlockType, _: u32) CallbackError!void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        const b = &self.builder;
        switch (block_type) {
            .doc, .hr, .html => {},
            .code => {
                try closeBuilder(b);
                try closeBuilder(b);
            }, // code + pre
            else => try closeBuilder(b),
        }
    }

    // ── Span events ────────────────────────────────────────────────────

    fn onEnterSpan(ptr: *anyopaque, span_type: SpanType, detail: SpanDetail) CallbackError!void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        const b = &self.builder;
        switch (span_type) {
            .em => try b.open("em", .{}),
            .strong => try b.open("strong", .{}),
            .u => try b.open("u", .{}),
            .code => try b.open("code", .{}),
            .del => try b.open("del", .{}),
            .latexmath, .latexmath_display => try b.open("x-equation", .{}),
            .a, .wikilink => {
                const href = try self.hrefValue(detail);
                const title = try self.optionalTitle(detail);
                try b.open("a", .{
                    attr("href", href),
                    if (title) |t| attr("title", t) else null,
                });
            },
            .img => {
                const src_val = try self.hrefValue(detail);
                const title = try self.optionalTitle(detail);
                try b.open("img", .{
                    attr("src", src_val),
                    if (title) |t| attr("title", t) else null,
                });
            },
        }
    }

    fn onLeaveSpan(ptr: *anyopaque, span_type: SpanType) CallbackError!void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        const b = &self.builder;
        if (span_type == .img) {
            // Images: pop the frame, collect alt text from children,
            // then emit a closed <img src="..." alt="..."> element.
            const f = try popRawBuilder(b);
            const src_val = for (f.attrs) |a| {
                if (std.mem.eql(u8, a.key, "src")) break a.value orelse "";
            } else "";
            const title = for (f.attrs) |a| {
                if (std.mem.eql(u8, a.key, "title")) break a.value;
            } else null;
            const alt = try collectText(self.alloc, f.children);
            try b.closedElement("img", .{
                attr("src", src_val),
                attr("alt", alt),
                if (title) |t| attr("title", t) else null,
            });
        } else try closeBuilder(b);
    }

    // ── Text events ────────────────────────────────────────────────────

    fn onText(ptr: *anyopaque, text_type: TextType, content: []const u8) CallbackError!void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        const b = &self.builder;
        switch (text_type) {
            .normal, .code, .entity, .latexmath => {
                const owned = try self.dupe(content);
                try b.text(owned);
            },
            .html => {
                const owned = try self.dupe(content);
                try b.raw(owned);
            },
            .null_char => {
                const owned = try self.dupe("\u{FFFD}");
                try b.text(owned);
            },
            .br => try b.closedElement("br", .{}),
            .softbr => {
                const owned = try self.dupe("\n");
                try b.text(owned);
            },
        }
    }
};

// ─── Helpers ───────────────────────────────────────────────────────────────

fn collectText(allocator: Allocator, nodes: []const Node) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try collectInto(&buf, allocator, nodes);
    return buf.toOwnedSlice(allocator);
}

fn collectInto(buf: *std.ArrayList(u8), alloc: Allocator, nodes: []const Node) Allocator.Error!void {
    for (nodes) |n| switch (n) {
        .text => |t| try buf.appendSlice(alloc, t),
        .raw => |r| try buf.appendSlice(alloc, r),
        .element => |el| try collectInto(buf, alloc, el.children),
        .fragment => |ch| try collectInto(buf, alloc, ch),
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
    return node.element.getAttr(key);
}

test "heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "# Hello");
    const ch = try expectElement(node, "h1");
    try expectText(ch[0], "Hello");
}

test "utf-8 bom is skipped before parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "\xEF\xBB\xBF# Hello");
    const ch = try expectElement(node, "h1");
    try expectText(ch[0], "Hello");
}

test "allocation failure propagates" {
    var buf: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try testing.expectError(error.OutOfMemory, parse(fba.allocator(), "# Hello"));
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

test "table alignment attrs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "| a | b | c |\n| :--- | :---: | ---: |\n| 1 | 2 | 3 |");
    const table = try expectElement(node, "table");
    const thead = try expectElement(table[0], "thead");
    const tr = try expectElement(thead[0], "tr");
    try testing.expectEqualStrings("text-align: left", expectAttr(tr[0], "style").?);
    try testing.expectEqualStrings("text-align: center", expectAttr(tr[1], "style").?);
    try testing.expectEqualStrings("text-align: right", expectAttr(tr[2], "style").?);
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

test "link title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "[text](/url \"Title\")");
    const p = try expectElement(node, "p");
    _ = try expectElement(p[0], "a");
    try testing.expectEqualStrings("/url", expectAttr(p[0], "href").?);
    try testing.expectEqualStrings("Title", expectAttr(p[0], "title").?);
}

test "email autolink href has mailto prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "<user@example.com>");
    const p = try expectElement(node, "p");
    _ = try expectElement(p[0], "a");
    try testing.expectEqualStrings("mailto:user@example.com", expectAttr(p[0], "href").?);
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

test "image title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "![alt text](/img.png \"Image title\")");
    const p = try expectElement(node, "p");
    const img = p[0];
    try testing.expectEqualStrings("/img.png", expectAttr(img, "src").?);
    try testing.expectEqualStrings("alt text", expectAttr(img, "alt").?);
    try testing.expectEqualStrings("Image title", expectAttr(img, "title").?);
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
    const full = try collectText(arena.allocator(), p);
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

test "void elements have closed flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // <hr> is a void element — must have closed=true.
    const hr = try parse(arena.allocator(), "---");
    try testing.expect(hr.element.closed);

    // <br> inside a paragraph.
    const br_doc = try parse(arena.allocator(), "foo  \nbar");
    const p = try expectElement(br_doc, "p");
    try testing.expect(p[1].element.closed);

    // <img> is a void element.
    const img_doc = try parse(arena.allocator(), "![alt](/img.png)");
    const img_p = try expectElement(img_doc, "p");
    try testing.expect(img_p[0].element.closed);
}

test "empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parse(arena.allocator(), "");
    try testing.expectEqual(.fragment, std.meta.activeTag(node));
    try testing.expectEqual(0, node.fragment.len);
}
