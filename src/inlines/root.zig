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

// Force sub-module tests to be included
comptime {
    _ = emphasis;
    _ = link;
    _ = code;
}
