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
        const inline_nodes = try inlines.parseInlinesWithRefs(allocator, block.content, ref_defs);

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
            .children = inline_nodes,
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
