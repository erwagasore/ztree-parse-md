# DESIGN — ztree-parse-md

GFM Markdown parser for ztree. Parses Markdown text into a ztree `Node` tree.

## Public API

```zig
pub const ParseError = error{ OutOfMemory, StackOverflow, InvalidMarkdownTree };
pub const FootnoteHtml = enum { list, both };
pub fn parse(arena: std.mem.Allocator, input: []const u8, footnote_html: FootnoteHtml = .list) ParseError!ztree.Node
pub fn parseWithScratch(arena: std.mem.Allocator, scratch: std.mem.Allocator, input: []const u8, footnote_html: FootnoteHtml = .list) ParseError!ztree.Node
pub fn parseOwned(backing_allocator: std.mem.Allocator, input: []const u8) ParseError!Document
```

`parseOwned` keeps `.list`. There is no `ParseOptions` struct.

| Package | Signature | Direction |
|---------|-----------|-----------|
| ztree-html | `render(node, writer)` | tree → writer |
| ztree-md | `render(node, writer)` | tree → writer |
| ztree-parse-md | `parse(arena, input)` → `Node` | input → tree |

## Principles

Inherited from the ztree ecosystem:

- **Pure functions whenever possible.** Data in, output out.
- **One way to do a thing.** No options, no aliases, no alternative parse modes — except footnotes: a closed `FootnoteHtml` (`.list` / `.both`) as a defaulted last argument on `parse` / `parseWithScratch`. That is the sole options exception. Existing 3-arg callers stay `.list`.
- **Arena allocator.** `parse()` expects an arena-like allocator. All nodes and slices are allocated from it; individual node deallocation is not supported. Caller frees everything in one shot.
- **Single-purpose functions composed together.**

## Architecture

Backend: [bun-md](https://github.com/erwagasore/bun-md) — a Zig port of
[md4c](https://github.com/mity/md4c) extracted from the
[Bun runtime](https://github.com/oven-sh/bun/tree/main/src/md).
CommonMark 0.31.2 compliant with GFM extensions (tables, strikethrough,
task lists, autolinks).

bun-md is a SAX-style parser: it emits enter/leave/text events. The
**adapter** (`src/adapter.zig`) converts this event stream into a ztree
`Node` tree using `ztree.TreeBuilder` — the library's imperative tree
builder designed for exactly this kind of SAX-to-tree conversion.

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
adapter → ztree.TreeBuilder
  │  b.open("h1", .{})
  │  b.text("Hello ")
  │  b.open("strong", .{})
  │  b.text("world")
  │  b.close()            // → element("strong", ...)
  │  b.close()            // → element("h1", ...)
  │  b.finish()
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
Output: ztree.Node          (allocated via provided arena)
Text nodes: copied           (parser uses internal buffers; text is
                              copied into arena during tree building)
Structure: []Node, []Attr   (arena-allocated)
Scratch parser memory:      (allocated via scratch allocator when using
                              parseWithScratch; otherwise via arena)
```

Caller-managed arena usage:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const tree = try parse(arena.allocator(), markdown_input);
// use tree... (render to HTML, etc.)
// arena.deinit() frees everything
```

Separate scratch allocator usage:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const tree = try parseWithScratch(arena.allocator(), allocator, markdown_input);
// scratch owns temporary parser allocations only;
// tree data remains in arena
```

Owned-document usage:

```zig
var doc = try parseOwned(allocator, markdown_input);
defer doc.deinit();
const tree = doc.root;
```

Raw HTML in Markdown is preserved as `raw()` nodes. Downstream HTML renderers
must sanitize untrusted input before or during rendering.

## File structure

```
src/
  root.zig         — public API (parse function)
  adapter.zig      — SAX-to-tree adapter (uses ztree.TreeBuilder + tests)
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
| `[^id]` (`.list` / `.both`) | `sup.fn` + `a` | `href` |
| `[^id]:` (`.list` / `.both`) | `section.footnotes` + `ol` + `li` | `id` on `li` |
| `[^id]` (`.both` extra) | `span.fn-body` inside `sup.fn` | `hidden`, `aria-hidden` |
| plain text | `text()` | — |
| raw HTML | `raw()` | — |

## Footnotes

The bun-md adapter does not emit footnotes today (`[^1]` stays ordinary text). `.list` **implements** GFM footnote HTML; it does not match current output.

- **`.list` (default):** `[^id]` → `sup.fn > a`; definitions → `section.footnotes > ol > li` with back-links. Ids stay on the canonical `<li>` (`id="fn-N"`).
- **`.both`:** the `.list` tree plus a hidden, `aria-hidden` near copy (`span.fn-body`) beside each reference. Near spans must not reuse `id="fn-N"`.
- Structural classes only: `fn`, `fn-body`, `footnotes` — not typography utilities.
- Documents with no footnotes are unchanged in either mode.
- Viewport / sidebar / popover placement is a consumer concern, not this parser.
