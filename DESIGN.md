# DESIGN — ztree-parse-md

GFM Markdown parser for ztree. Parses Markdown text into a ztree `Node` tree.

## Public API

```zig
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !ztree.Node
```

| Package | Signature | Direction |
|---------|-----------|-----------|
| ztree-html | `render(node, writer)` | tree → writer |
| ztree-md | `render(node, writer)` | tree → writer |
| ztree-parse-md | `parse(allocator, input)` → `Node` | input → tree |

## Principles

Inherited from the ztree ecosystem:

- **Pure functions whenever possible.** Data in, output out.
- **One way to do a thing.** No options, no aliases, no alternative parse modes.
- **Arena allocator.** Caller provides an allocator (intended to be an arena). All nodes and slices are allocated from it. Caller frees everything in one shot.
- **Single-purpose functions composed together.**

## Architecture

Backend: [bun-md](https://github.com/erwagasore/bun-md) — a Zig port of
[md4c](https://github.com/mity/md4c) extracted from the
[Bun runtime](https://github.com/oven-sh/bun/tree/main/src/md).
CommonMark 0.31.2 compliant with GFM extensions (tables, strikethrough,
task lists, autolinks).

bun-md is a SAX-style parser: it emits enter/leave/text events. The
**adapter** (`src/adapter.zig`) converts this event stream into a ztree
`Node` tree using a stack-based builder.

```
Input: []const u8
  │
  ▼
bun-md parser (SAX events)
  │  enterBlock(.h, 1, 0)
  │  text(.normal, "Hello ")
  │  enterSpan(.strong, ...)
  │  text(.normal, "world")
  │  leaveSpan(.strong)
  │  leaveBlock(.h, 1)
  │
  ▼
adapter (stack-based tree builder)
  │  push frame "h1"
  │  append text "Hello "
  │  push frame "strong"
  │  append text "world"
  │  pop frame → element("strong", ...)
  │  pop frame → element("h1", ...)
  │
  ▼
Output: ztree.Node
```

### Shim

bun-md source files import `@import("bun")` for Bun-specific APIs.
The shim (`src/shim/bun.zig`) provides stdlib replacements, injected
as a build-system module — zero edits to bun-md source files.

## Memory model

```
Input: []const u8          (owned by caller, must outlive parse call)
Output: ztree.Node          (allocated via provided allocator)
Text nodes: copied           (parser uses internal buffers; text is
                              copied into arena during tree building)
Structure: []Node, []Attr   (arena-allocated)
```

Caller usage:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const tree = try parse(arena.allocator(), markdown_input);
// use tree... (render to HTML, etc.)
// arena.deinit() frees everything
```

## File structure

```
src/
  root.zig         — public API (parse function)
  adapter.zig      — SAX-to-tree adapter (TreeBuilder + tests)
  shim/
    bun.zig        — stdlib shim for bun-md's @import("bun")
```

## Tag mapping

| Markdown | ztree tag | Attrs |
|----------|-----------|-------|
| `# ...` | `h1`–`h6` | — |
| paragraph | `p` | — |
| `> ...` | `blockquote` | — |
| `- ...` | `ul` + `li` | — |
| `1. ...` | `ol` + `li` | `start` |
| `- [x]` / `- [ ]` | `li` + `input` | `type`, `checked` |
| `` ``` `` | `pre` + `code` | `class="language-X"` |
| `---` | `hr` | — |
| `\|...\|` | `table` + `thead`/`tbody` + `tr` + `th`/`td` | `style` (alignment) |
| `**bold**` | `strong` | — |
| `*italic*` | `em` | — |
| `~~strike~~` | `del` | — |
| `` `code` `` | `code` | — |
| `[text](url)` | `a` | `href` |
| `![alt](src)` | `img` | `src`, `alt` |
| hard break | `br` | — |
| plain text | `text()` | — |
| raw HTML | `raw()` | — |

## Sync from upstream

See [bun-md README](https://github.com/erwagasore/bun-md#sync-from-upstream).
