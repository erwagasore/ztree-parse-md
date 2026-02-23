/// Tree builder — converts a flat list of Block descriptors into a ztree Node tree.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;
const Block = @import("../block/root.zig");
const inlines = @import("../inlines/root.zig");

// Sub-modules
const list_mod = @import("list.zig");
const code_mod = @import("code.zig");
const table_mod = @import("table.zig");

// Re-exports
pub const buildList = list_mod.buildList;
pub const buildCodeBlock = code_mod.buildCodeBlock;
pub const buildTableNode = table_mod.buildTableNode;

/// The parse function type — passed in to break the circular dependency for blockquote recursion.
pub const ParseFn = *const fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!Node;

/// Build a ztree Node tree from a flat list of blocks.
pub fn buildTree(allocator: std.mem.Allocator, blocks: []const Block.Block, parseFn: ParseFn) std.mem.Allocator.Error!Node {
    if (blocks.len == 0) return .{ .fragment = &.{} };

    var nodes: std.ArrayList(Node) = .empty;
    var footnotes: std.ArrayList(Block.Block) = .empty;
    var i: usize = 0;

    while (i < blocks.len) {
        const block = blocks[i];

        if (block.tag == .footnote_def) {
            try footnotes.append(allocator, block);
            i += 1;
        } else if (block.tag == .ul_item or block.tag == .ol_item) {
            const result = try buildList(allocator, blocks, i);
            try nodes.append(allocator, result.node);
            i = result.next;
        } else if (block.tag == .table) {
            try nodes.append(allocator, try buildTableNode(allocator, block.content));
            i += 1;
        } else if (block.tag == .blockquote) {
            const inner = try parseFn(allocator, block.content);
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
            const children = try inlines.parseInlines(allocator, block.content);
            try nodes.append(allocator, .{ .element = .{
                .tag = Block.tagName(block.tag),
                .attrs = &.{},
                .children = children,
            } });
            i += 1;
        }
    }

    // Append footnotes section if any definitions exist
    if (footnotes.items.len > 0) {
        try nodes.append(allocator, try buildFootnotesSection(allocator, footnotes.items));
    }

    return .{ .fragment = try nodes.toOwnedSlice(allocator) };
}

/// Build the footnotes section: section.footnotes > ol > li#fn-{id}
fn buildFootnotesSection(allocator: std.mem.Allocator, footnotes: []const Block.Block) std.mem.Allocator.Error!Node {
    var li_nodes: std.ArrayList(Node) = .empty;

    for (footnotes) |fn_block| {
        const id = fn_block.lang; // footnote id stored in lang field
        const content_nodes = try inlines.parseInlines(allocator, fn_block.content);

        // Build back-reference: a(href="#fnref-{id}") with text "↩"
        const backref_href = try std.fmt.allocPrint(allocator, "#fnref-{s}", .{id});
        const backref_attrs = try allocator.alloc(ztree.Attr, 1);
        backref_attrs[0] = .{ .key = "href", .value = backref_href };
        const backref_text = try allocator.alloc(Node, 1);
        backref_text[0] = .{ .text = "↩" };
        const backref = Node{ .element = .{ .tag = "a", .attrs = backref_attrs, .children = backref_text } };

        // Combine content + space + backref
        const li_children = try allocator.alloc(Node, content_nodes.len + 2);
        @memcpy(li_children[0..content_nodes.len], content_nodes);
        li_children[content_nodes.len] = .{ .text = " " };
        li_children[content_nodes.len + 1] = backref;

        // li with id="fn-{id}"
        const li_id = try std.fmt.allocPrint(allocator, "fn-{s}", .{id});
        const li_attrs = try allocator.alloc(ztree.Attr, 1);
        li_attrs[0] = .{ .key = "id", .value = li_id };

        try li_nodes.append(allocator, .{ .element = .{
            .tag = "li",
            .attrs = li_attrs,
            .children = li_children,
        } });
    }

    // ol
    const ol_children = try li_nodes.toOwnedSlice(allocator);
    const ol = try allocator.alloc(Node, 1);
    ol[0] = .{ .element = .{ .tag = "ol", .attrs = &.{}, .children = ol_children } };

    // section.footnotes
    const section_attrs = try allocator.alloc(ztree.Attr, 1);
    section_attrs[0] = .{ .key = "class", .value = "footnotes" };

    return .{ .element = .{
        .tag = "section",
        .attrs = section_attrs,
        .children = ol,
    } };
}

// Force sub-module tests to be included
comptime {
    _ = list_mod;
    _ = code_mod;
    _ = table_mod;
}
