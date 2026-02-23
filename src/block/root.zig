/// Block scanner — line-by-line classification into a flat list of Block descriptors.
const std = @import("std");

// Sub-modules
const heading = @import("heading.zig");
const fence = @import("fence.zig");
const list = @import("list.zig");
const line = @import("line.zig");
const blockquote = @import("blockquote.zig");
const tbl = @import("table.zig");
const footnote = @import("footnote.zig");
const utils = @import("utils.zig");

// Re-exports for external use
pub const classifyHeading = heading.classifyHeading;
pub const classifyFenceOpen = fence.classifyFenceOpen;
pub const isClosingFence = fence.isClosingFence;
pub const classifyListItem = list.classifyListItem;
pub const isBlankLine = line.isBlankLine;
pub const isThematicBreak = line.isThematicBreak;
pub const stripBlockquotePrefix = blockquote.stripBlockquotePrefix;
pub const isTableSeparator = tbl.isTableSeparator;
pub const isTableRow = tbl.isTableRow;
pub const classifyFootnoteDef = footnote.classifyFootnoteDef;
pub const joinLines = utils.joinLines;

pub const Tag = enum { h1, h2, h3, h4, h5, h6, p, pre, hr, blockquote, ul_item, ol_item, table, footnote_def };

pub const Block = struct {
    tag: Tag,
    content: []const u8,
    lang: []const u8 = "",
    indent: u8 = 0,
    checked: ?bool = null,
};

/// Scan input line-by-line and produce a flat list of Block descriptors.
pub fn parseBlocks(allocator: std.mem.Allocator, input: []const u8) ![]const Block {
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

    // Table state
    var in_table = false;
    var table_start: usize = 0;
    var table_end: usize = 0;

    var pos: usize = 0;
    while (pos < input.len) {
        const line_start = pos;
        const line_end = if (std.mem.indexOfScalar(u8, input[pos..], '\n')) |nl| pos + nl else input.len;
        const raw_line = input[line_start..line_end];
        pos = if (line_end < input.len) line_end + 1 else input.len;

        if (in_fence) {
            if (isClosingFence(raw_line, fence_backtick_count)) {
                const content = if (fence_content_start < line_start)
                    input[fence_content_start..line_start]
                else
                    "";
                try blocks.append(allocator, .{ .tag = .pre, .content = content, .lang = fence_lang });
                in_fence = false;
            }
            continue;
        }

        // Blockquote line — collect stripped lines
        if (stripBlockquotePrefix(raw_line)) |stripped| {
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

        if (isBlankLine(raw_line)) {
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            continue;
        }

        if (isThematicBreak(raw_line)) {
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            try blocks.append(allocator, .{ .tag = .hr, .content = "" });
            continue;
        }

        if (classifyListItem(raw_line)) |item| {
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

        if (classifyFenceOpen(raw_line)) |f| {
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            in_fence = true;
            fence_backtick_count = f.backtick_count;
            fence_lang = f.lang;
            fence_content_start = pos;
            continue;
        }

        if (classifyFootnoteDef(raw_line)) |f| {
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            try blocks.append(allocator, .{ .tag = .footnote_def, .content = f.content, .lang = f.id });
            continue;
        }

        if (classifyHeading(raw_line)) |h| {
            if (para_start) |start| {
                try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
                para_start = null;
            }
            try blocks.append(allocator, .{ .tag = h.tag, .content = h.content });
            continue;
        }

        // Table body rows — continue collecting while in table mode
        if (in_table) {
            if (isTableRow(raw_line)) {
                table_end = line_end;
                continue;
            } else {
                try blocks.append(allocator, .{ .tag = .table, .content = input[table_start..table_end] });
                in_table = false;
            }
        }

        // Table separator — check if previous paragraph line is a header
        if (!in_table and isTableSeparator(raw_line)) {
            if (para_start) |start| {
                const header_content = input[start..para_end];
                if (std.mem.indexOfScalar(u8, header_content, '\n') == null and std.mem.indexOfScalar(u8, header_content, '|') != null) {
                    table_start = start;
                    table_end = line_end;
                    in_table = true;
                    para_start = null;
                    continue;
                }
            }
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

    // Flush trailing table
    if (in_table) {
        try blocks.append(allocator, .{ .tag = .table, .content = input[table_start..table_end] });
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

/// Map a block tag to its HTML element name.
pub fn tagName(tag: Tag) []const u8 {
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
        .table => "table",
        .footnote_def => "li",
    };
}

// Force sub-module tests to be included
comptime {
    _ = heading;
    _ = fence;
    _ = list;
    _ = line;
    _ = blockquote;
    _ = tbl;
    _ = footnote;
}
