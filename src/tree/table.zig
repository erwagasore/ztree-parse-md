/// Table tree builder — `table > thead/tbody > tr > th/td` with alignment.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;
const inlines = @import("../inlines/root.zig");

pub const Align = enum { none, left, center, right };

/// Build a table element from the raw table content (header + separator + body rows).
pub fn buildTableNode(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error!Node {
    var lines: std.ArrayList([]const u8) = .empty;
    var lpos: usize = 0;
    while (lpos < content.len) {
        const end = std.mem.indexOfScalar(u8, content[lpos..], '\n');
        const line_end = if (end) |e| lpos + e else content.len;
        try lines.append(allocator, content[lpos..line_end]);
        lpos = if (line_end < content.len) line_end + 1 else content.len;
    }

    if (lines.items.len < 2) return .{ .fragment = &.{} };

    const header_line = lines.items[0];
    const sep_line = lines.items[1];

    // Parse alignment from separator
    const aligns = try parseAlignments(allocator, sep_line);

    // Build thead
    const header_cells = try parseTableRow(allocator, header_line, aligns, "th");
    const header_tr = try allocator.alloc(Node, 1);
    header_tr[0] = .{ .element = .{ .tag = "tr", .attrs = &.{}, .children = header_cells } };
    const thead = try allocator.alloc(Node, 1);
    thead[0] = .{ .element = .{ .tag = "thead", .attrs = &.{}, .children = header_tr } };

    // Build tbody
    if (lines.items.len > 2) {
        var body_rows: std.ArrayList(Node) = .empty;
        for (lines.items[2..]) |row_line| {
            const row_cells = try parseTableRow(allocator, row_line, aligns, "td");
            try body_rows.append(allocator, .{ .element = .{ .tag = "tr", .attrs = &.{}, .children = row_cells } });
        }

        const table_children = try allocator.alloc(Node, 2);
        table_children[0] = thead[0];
        table_children[1] = .{ .element = .{ .tag = "tbody", .attrs = &.{}, .children = try body_rows.toOwnedSlice(allocator) } };
        return .{ .element = .{ .tag = "table", .attrs = &.{}, .children = table_children } };
    }

    return .{ .element = .{ .tag = "table", .attrs = &.{}, .children = thead } };
}

/// Parse a table row into cells (th or td elements) with alignment attributes.
fn parseTableRow(allocator: std.mem.Allocator, raw_line: []const u8, aligns: []const Align, cell_tag: []const u8) std.mem.Allocator.Error![]const Node {
    var nodes: std.ArrayList(Node) = .empty;
    const trimmed = std.mem.trim(u8, raw_line, " \t");

    var pos: usize = 0;
    // Skip leading |
    if (pos < trimmed.len and trimmed[pos] == '|') pos += 1;

    var col: usize = 0;
    while (pos < trimmed.len) {
        const cell_start = pos;
        while (pos < trimmed.len and trimmed[pos] != '|') pos += 1;
        const raw_cell = trimmed[cell_start..pos];
        const cell_content = std.mem.trim(u8, raw_cell, " \t");

        // Skip trailing empty segment
        if (pos >= trimmed.len and cell_content.len == 0) break;

        const children = try inlines.parseInlines(allocator, cell_content);

        const col_align = if (col < aligns.len) aligns[col] else Align.none;
        const attrs: []const ztree.Attr = if (col_align != .none) blk: {
            const a = try allocator.alloc(ztree.Attr, 1);
            a[0] = .{ .key = "style", .value = switch (col_align) {
                .left => "text-align: left",
                .center => "text-align: center",
                .right => "text-align: right",
                .none => unreachable,
            } };
            break :blk a;
        } else &.{};

        try nodes.append(allocator, .{ .element = .{ .tag = cell_tag, .attrs = attrs, .children = children } });
        col += 1;
        if (pos < trimmed.len) pos += 1; // skip |
    }

    return try nodes.toOwnedSlice(allocator);
}

/// Parse alignment specifiers from the separator row.
fn parseAlignments(allocator: std.mem.Allocator, sep: []const u8) std.mem.Allocator.Error![]const Align {
    var aligns: std.ArrayList(Align) = .empty;
    const trimmed = std.mem.trim(u8, sep, " \t");

    var pos: usize = 0;
    // Skip leading |
    if (pos < trimmed.len and trimmed[pos] == '|') pos += 1;

    while (pos < trimmed.len) {
        // Find next |
        const cell_start = pos;
        while (pos < trimmed.len and trimmed[pos] != '|') pos += 1;
        const cell = std.mem.trim(u8, trimmed[cell_start..pos], " \t");

        if (cell.len > 0) {
            const starts_colon = cell[0] == ':';
            const ends_colon = cell[cell.len - 1] == ':';

            if (starts_colon and ends_colon) {
                try aligns.append(allocator, .center);
            } else if (ends_colon) {
                try aligns.append(allocator, .right);
            } else if (starts_colon) {
                try aligns.append(allocator, .left);
            } else {
                try aligns.append(allocator, .none);
            }
        }

        if (pos < trimmed.len) pos += 1; // skip |
    }

    return try aligns.toOwnedSlice(allocator);
}
