/// List tree builder — groups consecutive list item blocks into ul/ol elements.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;
const Block = @import("../block/root.zig");
const inlines = @import("../inlines/root.zig");

pub const ListResult = struct {
    node: Node,
    next: usize,
};

/// Group consecutive list item blocks into a ul/ol element, handling nesting via indentation.
pub fn buildList(allocator: std.mem.Allocator, blocks: []const Block.Block, start: usize, ref_defs: []const Block.RefDef) std.mem.Allocator.Error!ListResult {
    const base_indent = blocks[start].indent;
    const base_tag = blocks[start].tag;
    const list_tag: []const u8 = if (base_tag == .ul_item) "ul" else "ol";

    var li_nodes: std.ArrayList(Node) = .empty;
    var i = start;
    var is_loose = false;
    var seen_item = false;

    // First pass: detect if list is loose (blank between same-level items)
    {
        var j = start;
        var seen_blank = false;
        var items_seen: usize = 0;
        while (j < blocks.len) {
            const b = blocks[j];
            if (b.tag == .blank) {
                if (items_seen > 0) seen_blank = true;
                j += 1;
                continue;
            }
            if (b.tag != .ul_item and b.tag != .ol_item) break;
            if (b.indent < base_indent) break;
            if (b.indent == base_indent and b.tag != base_tag) break;
            if (b.indent == base_indent) {
                if (seen_blank and items_seen > 0) {
                    is_loose = true;
                    break;
                }
                items_seen += 1;
                seen_blank = false;
            }
            // Also check if any item has multi-paragraph content
            if (b.loose) is_loose = true;
            j += 1;
        }
    }

    while (i < blocks.len) {
        const block = blocks[i];

        // Skip blank markers
        if (block.tag == .blank) {
            i += 1;
            continue;
        }

        // Stop if not a list item
        if (block.tag != .ul_item and block.tag != .ol_item) break;
        // Stop if indent decreased below base
        if (block.indent < base_indent) break;
        // Stop if type changed at same indent level
        if (block.indent == base_indent and block.tag != base_tag) break;

        if (block.indent > base_indent) {
            // Nested list — build sub-list and attach to previous li
            const sub = try buildList(allocator, blocks, i, ref_defs);
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
        seen_item = true;
        const li_attrs: []const ztree.Attr = if (block.checked) |checked| blk: {
            if (checked) {
                const attrs = try allocator.alloc(ztree.Attr, 1);
                attrs[0] = .{ .key = "checked", .value = null };
                break :blk attrs;
            }
            break :blk &.{};
        } else &.{};

        if (is_loose or block.loose) {
            // Loose list or multi-paragraph item: wrap in <p> tags
            const children = try buildLooseItemChildren(allocator, block.content, ref_defs);
            try li_nodes.append(allocator, .{ .element = .{
                .tag = "li",
                .attrs = li_attrs,
                .children = children,
            } });
        } else {
            // Tight list: inline content directly in li
            const inline_nodes = try inlines.parseInlinesWithRefs(allocator, block.content, ref_defs);
            try li_nodes.append(allocator, .{ .element = .{
                .tag = "li",
                .attrs = li_attrs,
                .children = inline_nodes,
            } });
        }

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

/// Build children for a loose list item, splitting on \n\n into separate <p> elements.
fn buildLooseItemChildren(allocator: std.mem.Allocator, content: []const u8, ref_defs: []const Block.RefDef) std.mem.Allocator.Error![]const Node {
    var paras: std.ArrayList(Node) = .empty;
    var rest = content;

    while (rest.len > 0) {
        if (std.mem.indexOf(u8, rest, "\n\n")) |sep| {
            const para_content = rest[0..sep];
            const inline_nodes = try inlines.parseInlinesWithRefs(allocator, para_content, ref_defs);
            try paras.append(allocator, .{ .element = .{
                .tag = "p",
                .attrs = &.{},
                .children = inline_nodes,
            } });
            rest = rest[sep + 2 ..];
        } else {
            const inline_nodes = try inlines.parseInlinesWithRefs(allocator, rest, ref_defs);
            try paras.append(allocator, .{ .element = .{
                .tag = "p",
                .attrs = &.{},
                .children = inline_nodes,
            } });
            break;
        }
    }

    return try paras.toOwnedSlice(allocator);
}
