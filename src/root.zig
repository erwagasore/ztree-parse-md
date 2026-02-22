/// ztree-parse-md — GFM Markdown parser for ztree.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;

/// Parse Markdown text into a ztree Node tree.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!Node {
    const blocks = try parseBlocks(allocator, input);
    return buildTree(allocator, blocks);
}

// ---------------------------------------------------------------------------
// Pass 1 — Block scanner
// ---------------------------------------------------------------------------

const Tag = enum { h1, h2, h3, h4, h5, h6, p, pre, hr, blockquote, ul_item, ol_item };

const Block = struct {
    tag: Tag,
    content: []const u8,
    lang: []const u8 = "",
    indent: u8 = 0,
    checked: ?bool = null,
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

    // Blockquote state
    var bq_lines: std.ArrayList([]const u8) = .empty;

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

        // Blockquote line — collect stripped lines
        if (stripBlockquotePrefix(line)) |stripped| {
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            try bq_lines.append(allocator, stripped);
            continue;
        }

        // Not a blockquote line — flush any accumulated blockquote
        if (bq_lines.items.len > 0) {
            const inner = try joinLines(allocator, bq_lines.items);
            try blocks.append(allocator, .{ .tag = .blockquote, .content = inner });
            bq_lines.clearRetainingCapacity();
        }

        if (isBlankLine(line)) {
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            continue;
        }

        if (isThematicBreak(line)) {
            // Flush any open paragraph first
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            try blocks.append(allocator, .{ .tag = .hr, .content = "" });
            continue;
        }

        if (classifyListItem(line)) |item| {
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            try blocks.append(allocator, .{
                .tag = item.tag,
                .content = item.content,
                .indent = item.indent,
                .checked = item.checked,
            });
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

    // Flush trailing blockquote
    if (bq_lines.items.len > 0) {
        const inner = try joinLines(allocator, bq_lines.items);
        try blocks.append(allocator, .{ .tag = .blockquote, .content = inner });
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

/// A thematic break is a line containing 3+ of the same character (-, *, _)
/// with only optional spaces between them.
fn isThematicBreak(line: []const u8) bool {
    var char: ?u8 = null;
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ' or c == '\t') continue;
        if (c == '-' or c == '*' or c == '_') {
            if (char == null) {
                char = c;
            } else if (c != char.?) {
                return false;
            }
            count += 1;
        } else {
            return false;
        }
    }
    return count >= 3;
}

const ListItem = struct {
    tag: Tag,
    content: []const u8,
    indent: u8,
    checked: ?bool,
};

/// Classify a line as a list item. Supports `- `/`* ` (unordered) and `N. ` (ordered).
/// Detects task list markers `[x]`/`[ ]` on unordered items.
fn classifyListItem(line: []const u8) ?ListItem {
    // Count leading spaces
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    const indent: u8 = @intCast(i);

    if (i >= line.len) return null;

    var tag: Tag = undefined;
    var content_start: usize = undefined;

    // Unordered: - or * followed by space
    if ((line[i] == '-' or line[i] == '*') and i + 1 < line.len and line[i + 1] == ' ') {
        tag = .ul_item;
        content_start = i + 2;
    }
    // Ordered: digits followed by . and space
    else if (line[i] >= '0' and line[i] <= '9') {
        var j = i;
        while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
        if (j < line.len and line[j] == '.' and j + 1 < line.len and line[j + 1] == ' ') {
            tag = .ol_item;
            content_start = j + 2;
        } else {
            return null;
        }
    } else {
        return null;
    }

    const content = line[content_start..];

    // Task list: [x] or [ ] after unordered marker
    if (tag == .ul_item and content.len >= 3 and content[0] == '[') {
        const mark = content[1];
        if ((mark == 'x' or mark == ' ') and content[2] == ']') {
            if (content.len == 3 or content[3] == ' ') {
                const task_start: usize = if (content.len > 4) 4 else content.len;
                return .{
                    .tag = tag,
                    .content = content[task_start..],
                    .indent = indent,
                    .checked = mark == 'x',
                };
            }
        }
    }

    return .{ .tag = tag, .content = content, .indent = indent, .checked = null };
}

/// Strip the `> ` or `>` prefix from a blockquote line. Returns null if not a blockquote line.
fn stripBlockquotePrefix(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '>') return null;
    if (line.len > 1 and line[1] == ' ') return line[2..];
    return line[1..];
}

/// Join slices with newline separators into a single allocated buffer.
fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";

    var total: usize = 0;
    for (lines, 0..) |line, i| {
        total += line.len;
        if (i < lines.len - 1) total += 1;
    }

    const buf = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (lines, 0..) |line, i| {
        @memcpy(buf[offset .. offset + line.len], line);
        offset += line.len;
        if (i < lines.len - 1) {
            buf[offset] = '\n';
            offset += 1;
        }
    }

    return buf;
}

// ---------------------------------------------------------------------------
// Pass 2 — Tree builder + inline parser
// ---------------------------------------------------------------------------

/// Convert a list of Blocks into a ztree Node tree (a fragment of top-level elements).
fn buildTree(allocator: std.mem.Allocator, blocks: []const Block) std.mem.Allocator.Error!Node {
    if (blocks.len == 0) return .{ .fragment = &.{} };

    var nodes: std.ArrayList(Node) = .empty;
    var i: usize = 0;

    while (i < blocks.len) {
        const block = blocks[i];

        if (block.tag == .ul_item or block.tag == .ol_item) {
            const result = try buildList(allocator, blocks, i);
            try nodes.append(allocator, result.node);
            i = result.next;
        } else if (block.tag == .blockquote) {
            const inner = try parse(allocator, block.content);
            try nodes.append(allocator, .{ .element = .{
                .tag = "blockquote",
                .attrs = &.{},
                .children = inner.fragment,
            } });
            i += 1;
        } else if (block.tag == .hr) {
            try nodes.append(allocator, .{ .element = .{
                .tag = "hr",
                .attrs = &.{},
                .children = &.{},
            } });
            i += 1;
        } else if (block.tag == .pre) {
            try nodes.append(allocator, try buildCodeBlock(allocator, block));
            i += 1;
        } else {
            const children = try parseInlines(allocator, block.content);
            try nodes.append(allocator, .{ .element = .{
                .tag = tagName(block.tag),
                .attrs = &.{},
                .children = children,
            } });
            i += 1;
        }
    }

    return .{ .fragment = try nodes.toOwnedSlice(allocator) };
}

const ListResult = struct {
    node: Node,
    next: usize,
};

/// Group consecutive list item blocks into a ul/ol element, handling nesting via indentation.
fn buildList(allocator: std.mem.Allocator, blocks: []const Block, start: usize) std.mem.Allocator.Error!ListResult {
    const base_indent = blocks[start].indent;
    const base_tag = blocks[start].tag;
    const list_tag: []const u8 = if (base_tag == .ul_item) "ul" else "ol";

    var li_nodes: std.ArrayList(Node) = .empty;
    var i = start;

    while (i < blocks.len) {
        const block = blocks[i];
        // Stop if not a list item
        if (block.tag != .ul_item and block.tag != .ol_item) break;
        // Stop if indent decreased below base
        if (block.indent < base_indent) break;
        // Stop if type changed at same indent level
        if (block.indent == base_indent and block.tag != base_tag) break;

        if (block.indent > base_indent) {
            // Nested list — build sub-list and attach to previous li
            const sub = try buildList(allocator, blocks, i);
            if (li_nodes.items.len > 0) {
                const prev = &li_nodes.items[li_nodes.items.len - 1];
                const old = prev.element.children;
                const new_children = try allocator.alloc(Node, old.len + 1);
                @memcpy(new_children[0..old.len], old);
                new_children[old.len] = sub.node;
                prev.* = .{ .element = .{
                    .tag = "li",
                    .attrs = prev.element.attrs,
                    .children = new_children,
                } };
            }
            i = sub.next;
            continue;
        }

        // Same indent and type — new li
        const inlines = try parseInlines(allocator, block.content);

        const li_attrs: []const ztree.Attr = if (block.checked) |checked| blk: {
            if (checked) {
                const attrs = try allocator.alloc(ztree.Attr, 1);
                attrs[0] = .{ .key = "checked", .value = null };
                break :blk attrs;
            }
            break :blk &.{};
        } else &.{};

        try li_nodes.append(allocator, .{ .element = .{
            .tag = "li",
            .attrs = li_attrs,
            .children = inlines,
        } });

        i += 1;
    }

    return .{
        .node = .{ .element = .{
            .tag = list_tag,
            .attrs = &.{},
            .children = try li_nodes.toOwnedSlice(allocator),
        } },
        .next = i,
    };
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
fn parseInlines(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error![]const Node {
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
        } else if (content[pos] == '*') {
            // Count opening stars
            const star_start = pos;
            while (pos < content.len and content[pos] == '*') pos += 1;
            const star_count = pos - star_start;

            if (try handleEmphasis(allocator, content, star_start, star_count)) |result| {
                // Flush pending text
                if (text_start < star_start) {
                    try nodes.append(allocator, .{ .text = content[text_start..star_start] });
                }
                try nodes.append(allocator, result.node);
                pos = result.end;
                text_start = pos;
            }
            // No match — stars are literal text, pos already advanced past them.
        } else if (content[pos] == '!' and pos + 1 < content.len and content[pos + 1] == '[') {
            const marker_start = pos;
            if (try handleLinkOrImage(allocator, content, pos, true)) |result| {
                if (text_start < marker_start) {
                    try nodes.append(allocator, .{ .text = content[text_start..marker_start] });
                }
                try nodes.append(allocator, result.node);
                pos = result.end;
                text_start = pos;
            } else {
                pos += 2; // ![ is literal
            }
        } else if (content[pos] == '[') {
            const marker_start = pos;
            if (try handleLinkOrImage(allocator, content, pos, false)) |result| {
                if (text_start < marker_start) {
                    try nodes.append(allocator, .{ .text = content[text_start..marker_start] });
                }
                try nodes.append(allocator, result.node);
                pos = result.end;
                text_start = pos;
            } else {
                pos += 1; // [ is literal
            }
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

const EmphasisResult = struct {
    node: Node,
    end: usize,
};

/// Try to build an emphasis node from a star run. Returns null if no matching close found.
fn handleEmphasis(allocator: std.mem.Allocator, content: []const u8, star_start: usize, star_count: usize) std.mem.Allocator.Error!?EmphasisResult {
    const after_stars = star_start + star_count;

    // Don't open emphasis if followed by space or at end of content
    if (after_stars >= content.len or content[after_stars] == ' ') return null;

    if (star_count == 3) {
        // ***text*** → em(strong(text))
        if (findExactStarRun(content, after_stars, 3)) |close| {
            const inner = try parseInlines(allocator, content[after_stars..close]);
            const strong_children = try allocator.alloc(Node, 1);
            strong_children[0] = .{ .element = .{ .tag = "strong", .attrs = &.{}, .children = inner } };
            return .{
                .node = .{ .element = .{ .tag = "em", .attrs = &.{}, .children = strong_children } },
                .end = close + 3,
            };
        }
    }

    if (star_count >= 2) {
        // **text** → strong(text)
        if (findExactStarRun(content, after_stars, 2)) |close| {
            const inner = try parseInlines(allocator, content[after_stars..close]);
            return .{
                .node = .{ .element = .{ .tag = "strong", .attrs = &.{}, .children = inner } },
                .end = close + 2,
            };
        }
    }

    if (star_count >= 1) {
        // *text* → em(text)
        if (findExactStarRun(content, after_stars, 1)) |close| {
            const inner = try parseInlines(allocator, content[after_stars..close]);
            return .{
                .node = .{ .element = .{ .tag = "em", .attrs = &.{}, .children = inner } },
                .end = close + 1,
            };
        }
    }

    return null;
}

/// Find a `*` run of exactly `count` length, starting search at `start`.
/// Skips runs preceded by a space (not valid closers).
fn findExactStarRun(content: []const u8, start: usize, count: usize) ?usize {
    var pos = start;
    while (pos < content.len) {
        if (content[pos] == '*') {
            const run_start = pos;
            while (pos < content.len and content[pos] == '*') pos += 1;
            if (pos - run_start == count) {
                // Skip if preceded by space
                if (run_start > 0 and content[run_start - 1] == ' ') continue;
                return run_start;
            }
        } else {
            pos += 1;
        }
    }
    return null;
}

const LinkResult = struct {
    node: Node,
    end: usize,
};

/// Try to build a link or image from `[text](url)` or `![alt](src)` at the given position.
fn handleLinkOrImage(allocator: std.mem.Allocator, content: []const u8, pos: usize, is_image: bool) std.mem.Allocator.Error!?LinkResult {
    const bracket_start: usize = if (is_image) pos + 2 else pos + 1;

    // Find closing ]
    const bracket_end = (std.mem.indexOfScalar(u8, content[bracket_start..], ']') orelse return null) + bracket_start;

    // Must have ( immediately after ]
    if (bracket_end + 1 >= content.len or content[bracket_end + 1] != '(') return null;

    // Find closing ) with balanced parens
    const paren_start = bracket_end + 2;
    const paren_end = findClosingParen(content, paren_start) orelse return null;

    const text_content = content[bracket_start..bracket_end];
    const url_content = content[paren_start..paren_end];
    const url_info = parseUrlTitle(url_content);

    if (is_image) {
        const attr_count: usize = if (url_info.title != null) 3 else 2;
        const attrs = try allocator.alloc(ztree.Attr, attr_count);
        attrs[0] = .{ .key = "src", .value = url_info.url };
        attrs[1] = .{ .key = "alt", .value = text_content };
        if (url_info.title) |title| {
            attrs[2] = .{ .key = "title", .value = title };
        }
        return .{
            .node = .{ .element = .{ .tag = "img", .attrs = attrs, .children = &.{} } },
            .end = paren_end + 1,
        };
    } else {
        const attr_count: usize = if (url_info.title != null) 2 else 1;
        const attrs = try allocator.alloc(ztree.Attr, attr_count);
        attrs[0] = .{ .key = "href", .value = url_info.url };
        if (url_info.title) |title| {
            attrs[1] = .{ .key = "title", .value = title };
        }
        const children = try parseInlines(allocator, text_content);
        return .{
            .node = .{ .element = .{ .tag = "a", .attrs = attrs, .children = children } },
            .end = paren_end + 1,
        };
    }
}

/// Find closing `)` with balanced parentheses.
fn findClosingParen(content: []const u8, start: usize) ?usize {
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

const UrlTitle = struct {
    url: []const u8,
    title: ?[]const u8,
};

/// Parse URL and optional title from the content between `(` and `)`.
/// Supports `url`, `url "title"`, and `url 'title'`.
fn parseUrlTitle(content: []const u8) UrlTitle {
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
        .hr => "hr",
        .blockquote => "blockquote",
        .ul_item, .ol_item => "li",
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

// -- helper unit tests: classifyListItem --

test "classifyListItem — dash unordered" {
    const item = classifyListItem("- hello").?;
    try testing.expectEqual(.ul_item, item.tag);
    try testing.expectEqualStrings("hello", item.content);
    try testing.expectEqual(0, item.indent);
    try testing.expectEqual(null, item.checked);
}

test "classifyListItem — asterisk unordered" {
    const item = classifyListItem("* hello").?;
    try testing.expectEqual(.ul_item, item.tag);
    try testing.expectEqualStrings("hello", item.content);
}

test "classifyListItem — ordered" {
    const item = classifyListItem("1. first").?;
    try testing.expectEqual(.ol_item, item.tag);
    try testing.expectEqualStrings("first", item.content);
    try testing.expectEqual(0, item.indent);
}

test "classifyListItem — ordered multi-digit" {
    const item = classifyListItem("12. twelfth").?;
    try testing.expectEqual(.ol_item, item.tag);
    try testing.expectEqualStrings("twelfth", item.content);
}

test "classifyListItem — indented" {
    const item = classifyListItem("  - nested").?;
    try testing.expectEqual(.ul_item, item.tag);
    try testing.expectEqualStrings("nested", item.content);
    try testing.expectEqual(2, item.indent);
}

test "classifyListItem — task checked" {
    const item = classifyListItem("- [x] done").?;
    try testing.expectEqual(.ul_item, item.tag);
    try testing.expectEqualStrings("done", item.content);
    try testing.expectEqual(true, item.checked.?);
}

test "classifyListItem — task unchecked" {
    const item = classifyListItem("- [ ] todo").?;
    try testing.expectEqual(.ul_item, item.tag);
    try testing.expectEqualStrings("todo", item.content);
    try testing.expectEqual(false, item.checked.?);
}

test "classifyListItem — not a list (no space after dash)" {
    try testing.expectEqual(null, classifyListItem("-nope"));
}

test "classifyListItem — not a list (no space after dot)" {
    try testing.expectEqual(null, classifyListItem("1.nope"));
}

test "classifyListItem — not a list (plain text)" {
    try testing.expectEqual(null, classifyListItem("hello"));
}

test "classifyListItem — empty content" {
    const item = classifyListItem("- ").?;
    try testing.expectEqual(.ul_item, item.tag);
    try testing.expectEqualStrings("", item.content);
}

// -- helper unit tests: stripBlockquotePrefix --

test "stripBlockquotePrefix — with space" {
    try testing.expectEqualStrings("hello", stripBlockquotePrefix("> hello").?);
}

test "stripBlockquotePrefix — without space" {
    try testing.expectEqualStrings("hello", stripBlockquotePrefix(">hello").?);
}

test "stripBlockquotePrefix — bare >" {
    try testing.expectEqualStrings("", stripBlockquotePrefix(">").?);
}

test "stripBlockquotePrefix — > with space only" {
    try testing.expectEqualStrings("", stripBlockquotePrefix("> ").?);
}

test "stripBlockquotePrefix — not a blockquote" {
    try testing.expectEqual(null, stripBlockquotePrefix("hello"));
}

test "stripBlockquotePrefix — empty line" {
    try testing.expectEqual(null, stripBlockquotePrefix(""));
}

// -- helper unit tests: isThematicBreak --

test "isThematicBreak — three dashes" {
    try testing.expect(isThematicBreak("---"));
}

test "isThematicBreak — three asterisks" {
    try testing.expect(isThematicBreak("***"));
}

test "isThematicBreak — three underscores" {
    try testing.expect(isThematicBreak("___"));
}

test "isThematicBreak — more than three" {
    try testing.expect(isThematicBreak("-----"));
}

test "isThematicBreak — spaces between" {
    try testing.expect(isThematicBreak("- - -"));
}

test "isThematicBreak — spaces and tabs between" {
    try testing.expect(isThematicBreak(" * * * "));
}

test "isThematicBreak — two dashes not enough" {
    try testing.expect(!isThematicBreak("--"));
}

test "isThematicBreak — mixed chars rejected" {
    try testing.expect(!isThematicBreak("-*-"));
}

test "isThematicBreak — text content rejected" {
    try testing.expect(!isThematicBreak("--- text"));
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

// -- parse: thematic breaks --

test "thematic break — dashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "---");
    const nodes = try expectFragment(tree, 1);
    try testing.expectEqualStrings("hr", nodes[0].element.tag);
    try testing.expectEqual(0, nodes[0].element.children.len);
}

test "thematic break — asterisks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "***");
    const nodes = try expectFragment(tree, 1);
    try testing.expectEqualStrings("hr", nodes[0].element.tag);
}

test "thematic break — underscores" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "___");
    const nodes = try expectFragment(tree, 1);
    try testing.expectEqualStrings("hr", nodes[0].element.tag);
}

test "thematic break — between paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Above.\n\n---\n\nBelow.");
    const nodes = try expectFragment(tree, 3);
    try expectTextElement(nodes[0], "p", "Above.");
    try testing.expectEqualStrings("hr", nodes[1].element.tag);
    try expectTextElement(nodes[2], "p", "Below.");
}

test "thematic break — immediately after paragraph (no blank line)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Above.\n---");
    const nodes = try expectFragment(tree, 2);
    try expectTextElement(nodes[0], "p", "Above.");
    try testing.expectEqualStrings("hr", nodes[1].element.tag);
}

test "thematic break — with spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "- - -");
    const nodes = try expectFragment(tree, 1);
    try testing.expectEqualStrings("hr", nodes[0].element.tag);
}

// -- parse: blockquotes --

test "simple blockquote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "> Hello");
    const nodes = try expectFragment(tree, 1);
    try testing.expectEqualStrings("blockquote", nodes[0].element.tag);
    const inner = nodes[0].element.children;
    try testing.expectEqual(1, inner.len);
    try expectTextElement(inner[0], "p", "Hello");
}

test "blockquote — multi-line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "> Line 1\n> Line 2");
    const nodes = try expectFragment(tree, 1);
    try testing.expectEqualStrings("blockquote", nodes[0].element.tag);
    const inner = nodes[0].element.children;
    try testing.expectEqual(1, inner.len);
    try expectTextElement(inner[0], "p", "Line 1\nLine 2");
}

test "blockquote — with heading inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "> # Title\n>\n> Body.");
    const nodes = try expectFragment(tree, 1);
    try testing.expectEqualStrings("blockquote", nodes[0].element.tag);
    const inner = nodes[0].element.children;
    try testing.expectEqual(2, inner.len);
    try expectTextElement(inner[0], "h1", "Title");
    try expectTextElement(inner[1], "p", "Body.");
}

test "blockquote — between paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Before.\n\n> Quote.\n\nAfter.");
    const nodes = try expectFragment(tree, 3);
    try expectTextElement(nodes[0], "p", "Before.");
    try testing.expectEqualStrings("blockquote", nodes[1].element.tag);
    try expectTextElement(nodes[2], "p", "After.");
}

test "blockquote — nested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "> > Nested");
    const nodes = try expectFragment(tree, 1);
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
    const tree = try parse(arena.allocator(), "> First\n\n> Second");
    const nodes = try expectFragment(tree, 2);
    try testing.expectEqualStrings("blockquote", nodes[0].element.tag);
    try testing.expectEqualStrings("blockquote", nodes[1].element.tag);
}

test "blockquote — immediately after paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Text.\n> Quote.");
    const nodes = try expectFragment(tree, 2);
    try expectTextElement(nodes[0], "p", "Text.");
    try testing.expectEqualStrings("blockquote", nodes[1].element.tag);
}

test "blockquote — with inline code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "> Use `foo` here.");
    const nodes = try expectFragment(tree, 1);
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
    const tree = try parse(arena.allocator(), "- Alpha\n- Beta\n- Gamma");
    const nodes = try expectFragment(tree, 1);
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
    const tree = try parse(arena.allocator(), "1. First\n2. Second");
    const nodes = try expectFragment(tree, 1);
    const ol = nodes[0];
    try testing.expectEqualStrings("ol", ol.element.tag);
    try testing.expectEqual(2, ol.element.children.len);
    try expectTextElement(ol.element.children[0], "li", "First");
    try expectTextElement(ol.element.children[1], "li", "Second");
}

test "list — between paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Before.\n\n- A\n- B\n\nAfter.");
    const nodes = try expectFragment(tree, 3);
    try expectTextElement(nodes[0], "p", "Before.");
    try testing.expectEqualStrings("ul", nodes[1].element.tag);
    try expectTextElement(nodes[2], "p", "After.");
}

test "list — asterisk marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "* One\n* Two");
    const nodes = try expectFragment(tree, 1);
    try testing.expectEqualStrings("ul", nodes[0].element.tag);
    try testing.expectEqual(2, nodes[0].element.children.len);
}

test "list — mixed types are separate lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "- Unordered\n1. Ordered");
    const nodes = try expectFragment(tree, 2);
    try testing.expectEqualStrings("ul", nodes[0].element.tag);
    try testing.expectEqualStrings("ol", nodes[1].element.tag);
}

test "list — nested unordered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "- Parent\n  - Child 1\n  - Child 2\n- Sibling");
    const nodes = try expectFragment(tree, 1);
    const ul = nodes[0];
    try testing.expectEqualStrings("ul", ul.element.tag);
    try testing.expectEqual(2, ul.element.children.len);
    // First li has text + nested ul
    const li1 = ul.element.children[0];
    try testing.expectEqualStrings("li", li1.element.tag);
    try testing.expectEqual(2, li1.element.children.len);
    try testing.expectEqualStrings("Parent", li1.element.children[0].text);
    try testing.expectEqualStrings("ul", li1.element.children[1].element.tag);
    try testing.expectEqual(2, li1.element.children[1].element.children.len);
    // Second li is plain
    try expectTextElement(ul.element.children[1], "li", "Sibling");
}

test "list — nested ordered inside unordered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "- Item\n  1. Sub one\n  2. Sub two");
    const nodes = try expectFragment(tree, 1);
    const li = nodes[0].element.children[0];
    try testing.expectEqual(2, li.element.children.len);
    try testing.expectEqualStrings("ol", li.element.children[1].element.tag);
}

test "list — task list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "- [x] Done\n- [ ] Todo\n- Regular");
    const nodes = try expectFragment(tree, 1);
    const ul = nodes[0];
    try testing.expectEqual(3, ul.element.children.len);
    // Checked item has checked attr
    const done = ul.element.children[0];
    try testing.expectEqual(1, done.element.attrs.len);
    try testing.expectEqualStrings("checked", done.element.attrs[0].key);
    try testing.expectEqual(null, done.element.attrs[0].value);
    // Unchecked and regular have no attrs
    try testing.expectEqual(0, ul.element.children[1].element.attrs.len);
    try testing.expectEqual(0, ul.element.children[2].element.attrs.len);
}

test "list — with inline code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "- Use `foo`");
    const li = tree.fragment[0].element.children[0];
    try testing.expectEqual(2, li.element.children.len);
    try testing.expectEqualStrings("Use ", li.element.children[0].text);
    try testing.expectEqualStrings("code", li.element.children[1].element.tag);
}

test "list — single item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "- Solo");
    const nodes = try expectFragment(tree, 1);
    try testing.expectEqualStrings("ul", nodes[0].element.tag);
    try testing.expectEqual(1, nodes[0].element.children.len);
}

test "list — immediately after paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Text.\n- Item");
    const nodes = try expectFragment(tree, 2);
    try expectTextElement(nodes[0], "p", "Text.");
    try testing.expectEqualStrings("ul", nodes[1].element.tag);
}

// -- parse: emphasis --

test "em — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Hello *world*");
    const p = (try expectFragment(tree, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("Hello ", p.element.children[0].text);
    try testing.expectEqualStrings("em", p.element.children[1].element.tag);
    try testing.expectEqualStrings("world", p.element.children[1].element.children[0].text);
}

test "strong — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Hello **world**");
    const p = (try expectFragment(tree, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("Hello ", p.element.children[0].text);
    try testing.expectEqualStrings("strong", p.element.children[1].element.tag);
    try testing.expectEqualStrings("world", p.element.children[1].element.children[0].text);
}

test "em+strong — triple stars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "***bold italic***");
    const p = (try expectFragment(tree, 1))[0];
    try testing.expectEqual(1, p.element.children.len);
    const em = p.element.children[0];
    try testing.expectEqualStrings("em", em.element.tag);
    try testing.expectEqualStrings("strong", em.element.children[0].element.tag);
    try testing.expectEqualStrings("bold italic", em.element.children[0].element.children[0].text);
}

test "strong with em inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "**bold *italic* bold**");
    const p = (try expectFragment(tree, 1))[0];
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
    const tree = try parse(arena.allocator(), "*italic **bold** italic*");
    const p = (try expectFragment(tree, 1))[0];
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
    const tree = try parse(arena.allocator(), "*em* text");
    const p = (try expectFragment(tree, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("em", p.element.children[0].element.tag);
    try testing.expectEqualStrings(" text", p.element.children[1].text);
}

test "em — at end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "text *em*");
    const p = (try expectFragment(tree, 1))[0];
    try testing.expectEqual(2, p.element.children.len);
    try testing.expectEqualStrings("text ", p.element.children[0].text);
    try testing.expectEqualStrings("em", p.element.children[1].element.tag);
}

test "unmatched star — literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "a * b");
    const nodes = try expectFragment(tree, 1);
    try expectTextElement(nodes[0], "p", "a * b");
}

test "emphasis with code inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "**the `parse` function**");
    const p = (try expectFragment(tree, 1))[0];
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
    const tree = try parse(arena.allocator(), "## A **bold** heading");
    const h = (try expectFragment(tree, 1))[0];
    try testing.expectEqualStrings("h2", h.element.tag);
    try testing.expectEqual(3, h.element.children.len);
    try testing.expectEqualStrings("A ", h.element.children[0].text);
    try testing.expectEqualStrings("strong", h.element.children[1].element.tag);
    try testing.expectEqualStrings(" heading", h.element.children[2].text);
}

test "multiple emphasis spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "*a* and *b*");
    const p = (try expectFragment(tree, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("em", p.element.children[0].element.tag);
    try testing.expectEqualStrings(" and ", p.element.children[1].text);
    try testing.expectEqualStrings("em", p.element.children[2].element.tag);
}

// -- parse: links and images --

test "link — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "[click](https://example.com)");
    const p = (try expectFragment(tree, 1))[0];
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
    const tree = try parse(arena.allocator(), "[click](url \"My Title\")");
    const a = (try expectFragment(tree, 1))[0].element.children[0];
    try testing.expectEqual(2, a.element.attrs.len);
    try testing.expectEqualStrings("href", a.element.attrs[0].key);
    try testing.expectEqualStrings("url", a.element.attrs[0].value.?);
    try testing.expectEqualStrings("title", a.element.attrs[1].key);
    try testing.expectEqualStrings("My Title", a.element.attrs[1].value.?);
}

test "link — with emphasis inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "[**bold** link](url)");
    const a = (try expectFragment(tree, 1))[0].element.children[0];
    try testing.expectEqualStrings("a", a.element.tag);
    try testing.expectEqual(2, a.element.children.len);
    try testing.expectEqualStrings("strong", a.element.children[0].element.tag);
    try testing.expectEqualStrings(" link", a.element.children[1].text);
}

test "link — surrounded by text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "See [here](url) for details.");
    const p = (try expectFragment(tree, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("See ", p.element.children[0].text);
    try testing.expectEqualStrings("a", p.element.children[1].element.tag);
    try testing.expectEqualStrings(" for details.", p.element.children[2].text);
}

test "image — basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "![photo](img.jpg)");
    const p = (try expectFragment(tree, 1))[0];
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
    const tree = try parse(arena.allocator(), "![alt](src \"My Photo\")");
    const img = (try expectFragment(tree, 1))[0].element.children[0];
    try testing.expectEqual(3, img.element.attrs.len);
    try testing.expectEqualStrings("title", img.element.attrs[2].key);
    try testing.expectEqualStrings("My Photo", img.element.attrs[2].value.?);
}

test "image — surrounded by text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "Before ![pic](x.png) after.");
    const p = (try expectFragment(tree, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("Before ", p.element.children[0].text);
    try testing.expectEqualStrings("img", p.element.children[1].element.tag);
    try testing.expectEqualStrings(" after.", p.element.children[2].text);
}

test "link — unmatched bracket is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "just [text here");
    const nodes = try expectFragment(tree, 1);
    try expectTextElement(nodes[0], "p", "just [text here");
}

test "link — bracket without paren is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "[text] no link");
    const nodes = try expectFragment(tree, 1);
    try expectTextElement(nodes[0], "p", "[text] no link");
}

test "link — URL with balanced parens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "[wiki](https://en.wikipedia.org/wiki/Foo_(bar))");
    const a = (try expectFragment(tree, 1))[0].element.children[0];
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Foo_(bar)", a.element.attrs[0].value.?);
}

test "multiple links in one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "[a](1) and [b](2)");
    const p = (try expectFragment(tree, 1))[0];
    try testing.expectEqual(3, p.element.children.len);
    try testing.expectEqualStrings("a", p.element.children[0].element.tag);
    try testing.expectEqualStrings(" and ", p.element.children[1].text);
    try testing.expectEqualStrings("a", p.element.children[2].element.tag);
}

// -- helper unit tests: parseUrlTitle --

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
