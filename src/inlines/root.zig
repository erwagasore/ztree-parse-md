/// Inline parser — scans leaf block content for emphasis, links, images,
/// code spans, strikethrough, and line breaks.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;

// Sub-modules
const emphasis = @import("emphasis.zig");
const link = @import("link.zig");
const code = @import("code.zig");

// Re-exports for external use
pub const handleEmphasis = emphasis.handleEmphasis;
pub const findExactRun = emphasis.findExactRun;
pub const handleLinkOrImage = link.handleLinkOrImage;
pub const parseUrlTitle = link.parseUrlTitle;
pub const findClosingBackticks = code.findClosingBackticks;
pub const trimCodeSpan = code.trimCodeSpan;

const Block = @import("../block/root.zig");
const shared = @import("../utils.zig");

/// Parse inline Markdown within a leaf block's content.
/// Accepts optional reference link definitions for resolution.
pub fn parseInlines(allocator: std.mem.Allocator, content: []const u8, ref_defs: []const Block.RefDef) std.mem.Allocator.Error![]const Node {
    var nodes: std.ArrayList(Node) = .empty;
    var text_start: usize = 0;
    var pos: usize = 0;

    while (pos < content.len) {
        if (content[pos] == '\\' and pos + 1 < content.len and isEscapable(content[pos + 1])) {
            // Backslash escape — flush text before the backslash, skip it,
            // and let the escaped char start a new text run.
            try shared.flushText(&nodes, allocator, content, text_start, pos);
            pos += 1; // skip backslash
            text_start = pos; // escaped char becomes start of next text run
            pos += 1; // advance past escaped char
        } else if (content[pos] == '`') {
            // Count opening backticks
            const open_start = pos;
            while (pos < content.len and content[pos] == '`') pos += 1;
            const open_count = pos - open_start;

            // Find matching closing backticks (same count)
            if (findClosingBackticks(content, pos, open_count)) |close_start| {
                try shared.flushText(&nodes, allocator, content, text_start, open_start);

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
        } else if (content[pos] == '*' or content[pos] == '_') {
            // Count opening delimiter run (* or _)
            const delim = content[pos];
            const delim_start = pos;
            while (pos < content.len and content[pos] == delim) pos += 1;
            const delim_count = pos - delim_start;

            if (try handleEmphasis(allocator, content, delim_start, delim_count, delim, ref_defs)) |result| {
                try shared.flushText(&nodes, allocator, content, text_start, delim_start);
                try nodes.append(allocator, result.node);
                pos = result.end;
                text_start = pos;
            }
            // No match — delimiters are literal text, pos already advanced past them.
        } else if (content[pos] == '!' and pos + 1 < content.len and content[pos + 1] == '[') {
            const marker_start = pos;
            if (try handleLinkOrImage(allocator, content, pos, true, ref_defs)) |result| {
                try shared.flushText(&nodes, allocator, content, text_start, marker_start);
                try nodes.append(allocator, result.node);
                pos = result.end;
                text_start = pos;
            } else {
                pos += 2; // ![ is literal
            }
        } else if (content[pos] == '[') {
            const marker_start = pos;
            // Try footnote reference [^id] first
            if (try handleFootnoteRef(allocator, content, pos)) |result| {
                try shared.flushText(&nodes, allocator, content, text_start, marker_start);
                try nodes.append(allocator, result.node);
                pos = result.end;
                text_start = pos;
            } else if (try handleLinkOrImage(allocator, content, pos, false, ref_defs)) |result| {
                try shared.flushText(&nodes, allocator, content, text_start, marker_start);
                try nodes.append(allocator, result.node);
                pos = result.end;
                text_start = pos;
            } else {
                pos += 1; // [ is literal
            }
        } else if (content[pos] == '<') {
            // Autolink: <scheme://...>
            if (findAutolink(content, pos)) |result| {
                try shared.flushText(&nodes, allocator, content, text_start, pos);
                try nodes.append(allocator, try shared.buildAutolinkNode(allocator, result.url));
                pos = result.end;
                text_start = pos;
            } else if (findInlineHtml(content, pos)) |html_end| {
                try shared.flushText(&nodes, allocator, content, text_start, pos);
                try nodes.append(allocator, .{ .raw = content[pos..html_end] });
                pos = html_end;
                text_start = pos;
            } else {
                pos += 1; // < is literal
            }
        } else if (content[pos] == '~') {
            const tilde_start = pos;
            while (pos < content.len and content[pos] == '~') pos += 1;
            const tilde_count = pos - tilde_start;

            if (tilde_count == 2 and pos < content.len and content[pos] != ' ') {
                if (findExactRun(content, pos, '~', 2)) |close| {
                    try shared.flushText(&nodes, allocator, content, text_start, tilde_start);
                    const inner = try parseInlines(allocator, content[pos..close], ref_defs);
                    try nodes.append(allocator, .{ .element = .{ .tag = "del", .attrs = &.{}, .children = inner } });
                    pos = close + 2;
                    text_start = pos;
                }
            }
            // else: literal tildes, pos already advanced past them
        } else if (content[pos] == '&') {
            // HTML entity reference
            if (resolveEntity(content, pos)) |entity| {
                try shared.flushText(&nodes, allocator, content, text_start, pos);
                // Allocate decoded string on the arena so it outlives this function
                const decoded = try allocator.alloc(u8, entity.decoded.len);
                @memcpy(decoded, entity.decoded);
                try nodes.append(allocator, .{ .text = decoded });
                pos = entity.end;
                text_start = pos;
            } else {
                pos += 1; // & is literal
            }
        } else if (content[pos] == '\n') {
            // Check for hard line break
            var break_start = pos;
            var is_hard_break = false;

            if (pos >= 2 and content[pos - 1] == ' ' and content[pos - 2] == ' ') {
                // Two trailing spaces before newline
                is_hard_break = true;
                break_start = pos;
                while (break_start > text_start and content[break_start - 1] == ' ') {
                    break_start -= 1;
                }
            } else if (pos >= 1 and content[pos - 1] == '\\') {
                // Backslash before newline
                is_hard_break = true;
                break_start = pos - 1;
            }

            if (is_hard_break) {
                try shared.flushText(&nodes, allocator, content, text_start, break_start);
                try nodes.append(allocator, shared.makeVoidElement(allocator, "br", &.{}));
                pos += 1;
                text_start = pos;
            } else {
                pos += 1; // soft break — \n stays as text
            }
        } else if (content[pos] == 'h' and (pos == 0 or content[pos - 1] != '<')) {
            // GFM extended autolink: bare https:// or http:// URLs
            // Skip if preceded by < (that's angle-bracket autolink syntax)
            if (findBareUrl(content, pos)) |url_end| {
                try shared.flushText(&nodes, allocator, content, text_start, pos);
                try nodes.append(allocator, try shared.buildAutolinkNode(allocator, content[pos..url_end]));
                pos = url_end;
                text_start = pos;
            } else {
                pos += 1;
            }
        } else {
            pos += 1;
        }
    }

    // Flush remaining text
    try shared.flushText(&nodes, allocator, content, text_start, content.len);

    return try nodes.toOwnedSlice(allocator);
}

/// Detect a footnote reference `[^id]` at the given position.
/// Produces: sup > a(href="#fn-{id}", id="fnref-{id}") with text = id
fn handleFootnoteRef(allocator: std.mem.Allocator, content: []const u8, pos: usize) std.mem.Allocator.Error!?link.LinkResult {
    // Must start with [^
    if (pos + 2 >= content.len or content[pos] != '[' or content[pos + 1] != '^') return null;

    // Find closing ]
    const id_start = pos + 2;
    var id_end = id_start;
    while (id_end < content.len and content[id_end] != ']') id_end += 1;
    if (id_end >= content.len or id_end == id_start) return null; // no ] or empty id
    // Must not have ( after ] — that would be a link [^text](url)
    if (id_end + 1 < content.len and content[id_end + 1] == '(') return null;

    const id = content[id_start..id_end];

    // Build href="#fn-{id}" and id="fnref-{id}"
    const href = try std.fmt.allocPrint(allocator, "#fn-{s}", .{id});
    const ref_id = try std.fmt.allocPrint(allocator, "fnref-{s}", .{id});

    const href_attr = try allocator.alloc(ztree.Attr, 2);
    href_attr[0] = .{ .key = "href", .value = href };
    href_attr[1] = .{ .key = "id", .value = ref_id };

    const a_children = try allocator.alloc(Node, 1);
    a_children[0] = .{ .text = id };

    const sup_children = try allocator.alloc(Node, 1);
    sup_children[0] = .{ .element = .{ .tag = "a", .attrs = href_attr, .children = a_children } };

    return .{
        .node = .{ .element = .{ .tag = "sup", .attrs = &.{}, .children = sup_children } },
        .end = id_end + 1,
    };
}

const EntityResult = struct {
    decoded: []const u8,
    end: usize,
};

/// Resolve an HTML entity reference at the given position.
/// Supports named entities (&amp; &lt; &gt; &quot; &apos; &nbsp;)
/// and numeric entities (&#123; &#x1F;).
fn resolveEntity(content: []const u8, pos: usize) ?EntityResult {
    if (pos >= content.len or content[pos] != '&') return null;

    // Find closing ;
    const max_len = @min(pos + 12, content.len); // entities are short
    var end = pos + 1;
    while (end < max_len) : (end += 1) {
        if (content[end] == ';') break;
    } else {
        return null;
    }
    if (content[end] != ';') return null;

    const ref = content[pos + 1 .. end];
    if (ref.len == 0) return null;

    // Numeric: &#123; or &#x1F;
    if (ref[0] == '#') {
        if (ref.len < 2) return null;
        if (ref[1] == 'x' or ref[1] == 'X') {
            // Hex: &#xHH;
            const hex = ref[2..];
            if (hex.len == 0) return null;
            const cp = std.fmt.parseInt(u21, hex, 16) catch return null;
            return codePointToEntity(cp, end + 1);
        } else {
            // Decimal: &#DDD;
            const dec = ref[1..];
            const cp = std.fmt.parseInt(u21, dec, 10) catch return null;
            return codePointToEntity(cp, end + 1);
        }
    }

    // Named entities
    const decoded: []const u8 = if (std.mem.eql(u8, ref, "amp")) "&"
        else if (std.mem.eql(u8, ref, "lt")) "<"
        else if (std.mem.eql(u8, ref, "gt")) ">"
        else if (std.mem.eql(u8, ref, "quot")) "\""
        else if (std.mem.eql(u8, ref, "apos")) "'"
        else if (std.mem.eql(u8, ref, "nbsp")) "\u{00A0}"
        else if (std.mem.eql(u8, ref, "copy")) "\u{00A9}"
        else if (std.mem.eql(u8, ref, "mdash")) "\u{2014}"
        else if (std.mem.eql(u8, ref, "ndash")) "\u{2013}"
        else if (std.mem.eql(u8, ref, "hellip")) "\u{2026}"
        else if (std.mem.eql(u8, ref, "laquo")) "\u{00AB}"
        else if (std.mem.eql(u8, ref, "raquo")) "\u{00BB}"
        else return null;

    return .{ .decoded = decoded, .end = end + 1 };
}

fn codePointToEntity(cp: u21, end: usize) ?EntityResult {
    // Common ASCII codepoints used in entities
    return switch (cp) {
        '&' => .{ .decoded = "&", .end = end },
        '<' => .{ .decoded = "<", .end = end },
        '>' => .{ .decoded = ">", .end = end },
        '"' => .{ .decoded = "\"", .end = end },
        '\'' => .{ .decoded = "'", .end = end },
        ' ' => .{ .decoded = " ", .end = end },
        0x00A0 => .{ .decoded = "\u{00A0}", .end = end },
        0x00A9 => .{ .decoded = "\u{00A9}", .end = end },
        0x2014 => .{ .decoded = "\u{2014}", .end = end },
        0x2013 => .{ .decoded = "\u{2013}", .end = end },
        0x2026 => .{ .decoded = "\u{2026}", .end = end },
        else => {
            // For other ASCII, produce single byte
            if (cp >= 0x20 and cp < 0x7F) {
                const chars = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                const idx = cp - 0x20;
                return .{ .decoded = chars[idx .. idx + 1], .end = end };
            }
            return null;
        },
    };
}

/// Detect an inline HTML tag at the given position.
/// Matches opening tags `<tag ...>`, closing tags `</tag>`, self-closing `<tag/>`,
/// and HTML comments `<!-- ... -->`.
fn findInlineHtml(content: []const u8, pos: usize) ?usize {
    if (pos >= content.len or content[pos] != '<') return null;

    const start = pos + 1;
    if (start >= content.len) return null;

    // HTML comment <!-- ... -->
    if (content.len > pos + 3 and content[pos + 1] == '!' and content[pos + 2] == '-' and content[pos + 3] == '-') {
        if (std.mem.indexOf(u8, content[pos + 4 ..], "-->")) |close| {
            return pos + 4 + close + 3;
        }
        return null;
    }

    // Closing tag </tag>
    const is_closing = (content[start] == '/');
    const tag_start = if (is_closing) start + 1 else start;

    // Tag name must start with a letter
    if (tag_start >= content.len or !std.ascii.isAlphabetic(content[tag_start])) return null;

    // Find end of tag name
    var name_end = tag_start;
    while (name_end < content.len and (std.ascii.isAlphanumeric(content[name_end]) or content[name_end] == '-')) {
        name_end += 1;
    }
    if (name_end == tag_start) return null;

    const tag_name = content[tag_start..name_end];

    // Only match known HTML tags (not arbitrary words in angle brackets)
    if (!isKnownHtmlTag(tag_name)) return null;

    // Find closing >
    var end = name_end;
    while (end < content.len and content[end] != '>') {
        if (content[end] == '\n') return null; // no multi-line tags inline
        end += 1;
    }
    if (end >= content.len) return null;

    return end + 1; // past >
}

fn isKnownHtmlTag(name: []const u8) bool {
    const tags = [_][]const u8{
        "a", "abbr", "b", "bdi", "bdo", "br", "cite", "code", "data", "del",
        "dfn", "em", "i", "img", "input", "ins", "kbd", "mark", "q", "rp",
        "rt", "ruby", "s", "samp", "small", "span", "strong", "sub", "sup",
        "time", "u", "var", "wbr",
        // Also block-level for completeness
        "div", "p", "section", "article", "aside", "header", "footer", "nav",
        "main", "figure", "figcaption", "details", "summary", "blockquote",
        "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot",
        "tr", "th", "td", "caption", "colgroup", "col", "form", "fieldset",
        "legend", "select", "option", "optgroup", "textarea", "button", "label",
        "output", "progress", "meter", "iframe", "video", "audio", "source",
        "canvas", "svg", "math", "script", "style", "link", "meta", "title",
        "head", "body", "html", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "pre",
    };
    for (tags) |tag| {
        if (shared.eqlIgnoreCase(name, tag)) return true;
    }
    return false;
}

/// Detect a bare URL (GFM extended autolink) starting at pos.
/// Matches http:// or https:// followed by non-space characters.
/// Returns the end position of the URL, or null.
fn findBareUrl(content: []const u8, pos: usize) ?usize {
    const rest = content[pos..];
    const scheme_len: usize = if (std.mem.startsWith(u8, rest, "https://"))
        8
    else if (std.mem.startsWith(u8, rest, "http://"))
        7
    else
        return null;

    // Must have at least one char after scheme
    if (rest.len <= scheme_len) return null;

    // Find end of URL — stop at space, <, >, newline, or end
    var end = scheme_len;
    while (end < rest.len) {
        const c = rest[end];
        if (c == ' ' or c == '\t' or c == '\n' or c == '<' or c == '>') break;
        end += 1;
    }

    // Strip trailing punctuation that's likely not part of the URL
    while (end > scheme_len and (rest[end - 1] == '.' or rest[end - 1] == ',' or
        rest[end - 1] == ')' or rest[end - 1] == ';' or rest[end - 1] == ':' or
        rest[end - 1] == '!' or rest[end - 1] == '?'))
    {
        end -= 1;
    }

    if (end <= scheme_len) return null;
    return pos + end;
}

const AutolinkResult = struct {
    url: []const u8,
    end: usize,
};

/// Detect an autolink `<scheme://...>` at the given position.
fn findAutolink(content: []const u8, pos: usize) ?AutolinkResult {
    if (pos >= content.len or content[pos] != '<') return null;
    const start = pos + 1;

    // Find closing >
    const close = std.mem.indexOfScalar(u8, content[start..], '>') orelse return null;
    const url = content[start .. start + close];

    // Must contain :// (scheme separator) and no spaces
    if (std.mem.indexOf(u8, url, "://") == null) return null;
    if (std.mem.indexOfScalar(u8, url, ' ') != null) return null;

    return .{ .url = url, .end = start + close + 1 };
}

/// CommonMark escapable punctuation characters.
fn isEscapable(c: u8) bool {
    return switch (c) {
        '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '~', '"' => true,
        else => false,
    };
}

// Force sub-module tests to be included
comptime {
    _ = emphasis;
    _ = link;
    _ = code;
}
