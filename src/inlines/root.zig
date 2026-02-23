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

/// Parse inline Markdown within a leaf block's content.
pub fn parseInlines(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error![]const Node {
    var nodes: std.ArrayList(Node) = .empty;
    var text_start: usize = 0;
    var pos: usize = 0;

    while (pos < content.len) {
        if (content[pos] == '\\' and pos + 1 < content.len and isEscapable(content[pos + 1])) {
            // Backslash escape — flush text before the backslash, skip it,
            // and let the escaped char start a new text run.
            if (text_start < pos) {
                try nodes.append(allocator, .{ .text = content[text_start..pos] });
            }
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
        } else if (content[pos] == '*' or content[pos] == '_') {
            // Count opening delimiter run (* or _)
            const delim = content[pos];
            const delim_start = pos;
            while (pos < content.len and content[pos] == delim) pos += 1;
            const delim_count = pos - delim_start;

            if (try handleEmphasis(allocator, content, delim_start, delim_count, delim)) |result| {
                // Flush pending text
                if (text_start < delim_start) {
                    try nodes.append(allocator, .{ .text = content[text_start..delim_start] });
                }
                try nodes.append(allocator, result.node);
                pos = result.end;
                text_start = pos;
            }
            // No match — delimiters are literal text, pos already advanced past them.
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
        } else if (content[pos] == '<') {
            // Autolink: <scheme://...>
            if (findAutolink(content, pos)) |result| {
                if (text_start < pos) {
                    try nodes.append(allocator, .{ .text = content[text_start..pos] });
                }
                const attrs = try allocator.alloc(ztree.Attr, 1);
                attrs[0] = .{ .key = "href", .value = result.url };
                const children = try allocator.alloc(Node, 1);
                children[0] = .{ .text = result.url };
                try nodes.append(allocator, .{ .element = .{ .tag = "a", .attrs = attrs, .children = children } });
                pos = result.end;
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
                    if (text_start < tilde_start) {
                        try nodes.append(allocator, .{ .text = content[text_start..tilde_start] });
                    }
                    const inner = try parseInlines(allocator, content[pos..close]);
                    try nodes.append(allocator, .{ .element = .{ .tag = "del", .attrs = &.{}, .children = inner } });
                    pos = close + 2;
                    text_start = pos;
                }
            }
            // else: literal tildes, pos already advanced past them
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
                if (text_start < break_start) {
                    try nodes.append(allocator, .{ .text = content[text_start..break_start] });
                }
                try nodes.append(allocator, .{ .element = .{ .tag = "br", .attrs = &.{}, .children = &.{} } });
                pos += 1;
                text_start = pos;
            } else {
                pos += 1; // soft break — \n stays as text
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
