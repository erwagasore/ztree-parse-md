# ztree-parse-md

GFM Markdown parser for ztree v2. Parses Markdown text into a ztree `Node` tree that can be rendered by `ztree-html` or `ztree-md`.

## Quickstart

```bash
git clone git@github.com:erwagasore/ztree-parse-md.git
cd ztree-parse-md
zig build        # build library
zig build test   # run tests
```

## Usage

```zig
const std = @import("std");
const md = @import("ztree-parse-md");

var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

const tree: md.Node = try md.parse(arena.allocator(), markdown_input);
```

`parse()` allocates the returned tree with the provided arena-like allocator;
individual node deallocation is not supported.

For app-level code that wants the parser to manage the arena:

```zig
var doc = try md.parseOwned(allocator, markdown_input);
defer doc.deinit();

const tree = doc.root;
```

For advanced callers, `parseWithScratch(arena, scratch, input)` stores the
returned tree in `arena` while using `scratch` only during parsing.

Possible parse errors are exposed as `md.ParseError`.

Raw HTML in Markdown is preserved as `raw()` nodes. If rendering untrusted
input to HTML, sanitize before or during rendering.

## Structure

See [AGENTS.md](AGENTS.md#repo-map) for the full repo map.
