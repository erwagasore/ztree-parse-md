# Changelog

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
