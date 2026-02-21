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

- **Pure functions whenever possible.** Data in, output out. Helpers have no side effects.
- **One way to do a thing.** No options, no aliases, no alternative parse modes.
- **Arena allocator.** Caller provides an allocator (intended to be an arena). All nodes and slices are allocated from it. Caller frees everything in one shot.
- **Zero-copy text.** Text nodes are slices into the original input — no copies. `"Hello "` in the output points directly into the input buffer.
- **No intermediate AST.** No linked-list tree that gets converted. Build ztree nodes directly during parsing.
- **Single file.** `src/root.zig` — public API and all implementation.
- **Small, single-purpose functions composed together.**

## Memory model

```
Input: []const u8          (owned by caller, must outlive returned Node)
Output: ztree.Node          (allocated via provided allocator)
Text nodes: slices of input (zero-copy)
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

## Architecture

Two passes:

### Pass 1 — Block scanner

Line-by-line scan. Classifies each line by prefix and determines block structure.

```
"# ..."          → heading (level from # count)
"```..."         → code fence open/close
"> ..."          → blockquote
"- ..." / "1. ." → list item
"---" / "***"    → thematic break
"|...|...|"      → table row (after detecting delimiter row)
""               → blank line (ends paragraphs)
anything else    → paragraph continuation
```

Uses a stack for nesting (blockquotes, lists). Produces a flat list of `Block` descriptors:

```zig
const Block = struct {
    tag: Tag,            // h1, p, pre, hr, blockquote, ul, ol, table, ...
    content: []const u8, // slice of input (text content, prefixes stripped)
    level: u8,           // heading level, list depth, etc.
};
```

### Pass 2 — Inline parser + tree builder

Walks the block list. For leaf blocks (headings, paragraphs, table cells), parses inline Markdown into ztree nodes:

```
**bold**      → element("strong", &.{}, &.{text("bold")})
*italic*      → element("em", &.{}, &.{text("italic")})
~~strike~~    → element("del", &.{}, &.{text("strike")})
`code`        → element("code", &.{}, &.{text("code")})
[text](url)   → element("a", &.{attr("href", url)}, &.{text("text")})
![alt](src)   → closedElement("img", &.{attr("src", src), attr("alt", alt)})
```

All text is zero-copy — slices of the input.

## Function structure

```
parse()              — public entry point
  parseBlocks()      — pass 1: line scanner → []Block
  buildTree()        — pass 2: blocks → Node tree
    parseInlines()   — delimiter algorithm for emphasis/links/code
```

Pure helpers (no allocator, no side effects):

```
classifyLine()       — line → block type + content slice
stripPrefix()        — remove "> ", "# ", "- " etc.
findDelimiterRun()   — scan for *, **, `, [, ![
isThematicBreak()    — "---", "***", "___" detection
isFenceLine()        — "```" detection
isTableDelimiter()   — "|---|---|" detection
```

## Tag mapping

| Markdown | ztree tag | Attrs |
|----------|-----------|-------|
| `# ...` | `h1` | — |
| `## ...` | `h2` | — |
| `### ...` | `h3` | — |
| `#### ...` | `h4` | — |
| `##### ...` | `h5` | — |
| `###### ...` | `h6` | — |
| paragraph | `p` | — |
| `> ...` | `blockquote` | — |
| `- ...` | `ul` + `li` | — |
| `1. ...` | `ol` + `li` | — |
| `- [x]` / `- [ ]` | `li` | `checked` / — |
| `` ``` `` | `pre` + `code` | `class="language-X"` |
| `---` | `hr` | — |
| `\|...\|` | `table` + `thead`/`tbody` + `tr` + `th`/`td` | — |
| `**bold**` | `strong` | — |
| `*italic*` | `em` | — |
| `~~strike~~` | `del` | — |
| `` `code` `` | `code` | — |
| `[text](url)` | `a` | `href`, `title` |
| `![alt](src)` | `img` | `src`, `alt`, `title` |
| hard break | `br` | — |
| plain text | `text()` | — |
| raw HTML | `raw()` | — |

## h1 trace

Input: `"# Hello **world**\n"`

**Pass 1 — Block scanner:**

```
Line: "# Hello **world**"
  → detect "# " prefix → Tag.h1, content = "Hello **world**"
  → emit Block{ .tag = .h1, .content = "Hello **world**", .level = 1 }
```

**Pass 2 — Inline parse `"Hello **world**"`:**

```
scan "Hello "     → text node, slice input[2..8]
scan "**"         → push strong delimiter
scan "world"      → text node, slice input[10..15]
scan "**"         → pop strong delimiter, wrap children
```

**Build tree:**

```zig
const strong_kids = try arena.alloc(Node, 1);
strong_kids[0] = .{ .text = "world" };    // slice of input

const h1_kids = try arena.alloc(Node, 2);
h1_kids[0] = .{ .text = "Hello " };       // slice of input
h1_kids[1] = .{ .element = .{
    .tag = "strong",
    .attrs = &.{},
    .children = strong_kids,
} };

// result:
.{ .element = .{ .tag = "h1", .attrs = &.{}, .children = h1_kids } }
```

## Build plan

| Step | Blocks | Inlines | What it unlocks |
|------|--------|---------|-----------------|
| 1 | headings, paragraphs, blank lines | plain text only | basic structure |
| 2 | code blocks (fenced) | inline code | code paths |
| 3 | thematic breaks | — | trivial |
| 4 | blockquotes | — | nesting |
| 5 | lists (ul, ol) | — | hardest block type |
| 6 | — | emphasis (`*`, `**`) | hardest inline type |
| 7 | — | links, images | bracket matching |
| 8 | — | strikethrough, line breaks | GFM extensions |
| 9 | tables | — | GFM tables |

Each step is a shippable increment. Step 1 alone gives a working blog pipeline for plain-text posts.
