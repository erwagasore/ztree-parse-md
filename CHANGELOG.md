# Changelog

## [2.0.0] — 2026-05-02

### Breaking Changes

- Align the Markdown parser with the ztree v2 renderer ecosystem, changing the public parsed `Node` type to ztree v2.

### Features

- Upgrade ztree dependency to v2.0.0 for compatibility with ztree-html and ztree-md.
- Upgrade bun-md dependency to v0.2.1 for Zig 0.16 compatibility.
- Add explicit `ParseError`, `Node` re-export, and arena-backed `parseOwned()`/`Document` APIs.
- Preserve link/image `title` attributes and normalize email/www autolink hrefs.

### Fixes

- Parse BOM-stripped Markdown input consistently so parser offsets and adapter source slices stay aligned.
- Propagate adapter allocation and tree-builder failures instead of silently producing partial trees.

### Other

- Include README, design notes, changelog, and license in packaged paths.

## [1.3.0] — 2026-03-08

### Features

- Upgrade ztree dependency from v1.0.0 to v1.2.0 — picks up `Element.getAttr()`/`Element.hasAttr()` for attribute lookup and `Walker` type-erased re-entrant walker for downstream renderers.
- Replace manual attribute scan in test helper with `Element.getAttr()`.

## [1.2.0] — 2026-03-08

### Features

- Upgrade ztree dependency from v0.9.0 to v1.0.0 — picks up `WalkAction` for `renderWalk`, enabling downstream renderers to handle complex elements (tables, code blocks) entirely in `elementOpen` by returning `.skip_children`. Makes the tree fully usable by non-HTML renderers (Markdown, JSON, Ziggy, etc.) without subtree buffering.

## [1.1.0] — 2026-03-06

### Features

- Upgrade ztree dependency from v0.6.0 to v0.9.0 — picks up `Element.closed` field for void elements, `TreeBuilder.Error` type, `addNode()`, and tuple attrs support.
- Adopt tuple attrs throughout the adapter, replacing verbose manual `Attr` slice construction with ergonomic `.{ attr("key", "val") }` syntax.
- Collapse checked/unchecked task list branches into a single conditional tuple expression.
- Add test verifying `closed` flag on void elements (`hr`, `br`, `img`).

## [1.0.1] — 2026-03-05

### Fixes

- Pin ztree to latest commit with attr() export fix.
- Fix mutable binding for toOwnedSlice() in adapter pop().
- Update bun-md dependency hash.

### Other

- Replace hand-rolled tree builder with `ztree.TreeBuilder` and `popRaw()` from ztree v0.6.0.
- Update DESIGN.md architecture diagram.

## [1.0.0] — 2026-02-24

### Breaking Changes

- Replaced hand-written parser with bun-md backend (Zig port of md4c from Bun). Gains full CommonMark 0.31.2 + GFM compliance (tables, strikethrough, task lists, autolinks). Public API unchanged but output tree structure may differ in edge cases.
- Removed 20 hand-written parser files (`src/block/`, `src/inlines/`, `src/tree/`, `src/utils.zig`), replaced by SAX-to-tree adapter (`src/adapter.zig`) and stdlib shim (`src/shim/bun.zig`).

### Other

- Extracted shared utilities and deduplicated patterns across parser modules.

## [0.14.0] — 2026-02-23

### Features

- Extended autolinks (GFM): bare `https://` and `http://` URLs auto-linked without angle brackets, with trailing punctuation stripping
- Inline HTML pass-through: known HTML tags (`<em>`, `<br/>`, `<span>`, `<!-- comments -->`) preserved as raw nodes
- Block HTML pass-through: block-level tags (`<div>`, `<section>`, `<script>`, etc.) preserved as raw content blocks
- Tight vs loose lists: lists with blank lines between items wrap content in `<p>` tags
- Multi-paragraph list items: blank line + indented continuation creates additional `<p>` elements within the same `<li>`

## [0.13.0] — 2026-02-23

### Features

- Intra-word underscore rules: `foo_bar_baz` stays literal — underscores only open/close emphasis at word boundaries (CommonMark compliant)
- Nested mixed emphasis: `*foo **bar** baz*` correctly produces `em` wrapping `strong`
- HTML entity references: named (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, `&nbsp;`, `&copy;`, `&mdash;`, `&ndash;`, `&hellip;`) and numeric (`&#38;`, `&#x26;`) entities decoded to literal characters

## [0.12.0] — 2026-02-23

### Features

- Setext headings: `===` underline → h1, `---` underline → h2 (CommonMark-correct precedence over thematic breaks)
- Indented code blocks: 4-space indent → `pre > code` with blank line merging and trailing blank stripping

## [0.11.0] — 2026-02-23

### Features

- Footnotes: `[^id]` inline references → `sup > a`, `[^id]: content` definitions → `section.footnotes > ol > li` with back-reference links
- Reference links: full `[text][ref]`, collapsed `[text][]`, and shortcut `[text]` forms with `[ref]: url "title"` definitions
- Image references: `![alt][ref]` with same resolution rules
- Case-insensitive label matching for reference links
- Reference definitions support angle-bracket URLs and double/single/paren title styles

## [0.10.0] — 2026-02-23

### Features

- Escape sequences (`\*`, `\[`, `\~`, `\\`, etc.) — backslash before punctuation produces the literal character
- Underscore emphasis: `_em_`, `__strong__`, `___em+strong___`
- Autolinks: `<https://url>` → clickable `a` element

### Other

- Split monolithic `src/root.zig` into `block/`, `inlines/`, and `tree/` modules (17 files)

## [0.9.0] — 2026-02-23

### Features

- GFM tables with `thead`/`tbody`/`tr`/`th`/`td` structure
- Column alignment via `:---`, `:---:`, `---:` separator syntax → `style` attribute

## [0.8.0] — 2026-02-22

### Features

- GFM strikethrough `~~text~~` → `del` element with recursive inner parsing
- Hard line breaks via two trailing spaces or backslash before newline → `br` element

## [0.7.0] — 2026-02-22

### Features

- Links `[text](url)` and images `![alt](src)` with optional quoted titles and balanced parentheses in URLs

## [0.6.0] — 2026-02-22

### Features

- Emphasis: `*em*`, `**strong**`, and `***em+strong***` with recursive nesting

## [0.5.0] — 2026-02-22

### Features

- Unordered and ordered lists (`ul`, `ol`) with nesting via indentation
- GFM task list markers (`- [x]`/`- [ ]`) with `checked` attribute

## [0.4.0] — 2026-02-22

### Features

- Blockquotes (`> `) with recursive inner parsing and nesting support

## [0.3.0] — 2026-02-22

### Features

- Thematic breaks (`---`, `***`, `___`) rendered as `hr` elements

## [0.2.0] — 2026-02-22

### Features

- Fenced code blocks with optional language class (`pre > code`)
- Inline code spans with single and multi-backtick matching

## [0.1.0] — 2026-02-22

### Features

- Parse headings (`h1`–`h6`), paragraphs, and blank lines into ztree nodes

### Other

- Add README, AGENTS, LICENSE, and docs index
