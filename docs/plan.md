# Configurable footnote HTML

Implement GFM footnote HTML in `ztree-parse-md`, with a closed `FootnoteHtml` mode: `.list` (default) is the canonical bottom section only; `.both` adds hidden near-reference copies. This is an intentional exception to “no parse options.”

## How to use

1. Pick the next unchecked task whose dependencies are complete.
2. Create a dedicated branch for that task and land it independently.
3. Tick the task only after its change has merged.

## Phase 1 — Contract

- [ ] **`docs(design): allow a footnote HTML mode option`**

  Update [`DESIGN.md`](../DESIGN.md) (public API and [Principles](../DESIGN.md#principles): “One way to do a thing. No options…”). Record a closed `FootnoteHtml` mode. The bun-md adapter does not emit footnotes today (`[^1]` stays ordinary text). `.list` (default) **implements** GFM footnote HTML: `[^id]` → `sup.fn > a`, definitions → `section.footnotes > ol > li` with back-links. `.both` additionally inserts a hidden, `aria-hidden` near copy beside each reference. Ids stay on the canonical `<li>` (`id="fn-N"`); near spans must not reuse those ids. `parse` / `parseWithScratch` keep their current arguments and add one defaulted last parameter `footnote_html: FootnoteHtml = .list`, so existing 3-arg callers stay `.list`. No `ParseOptions` struct. No other parse modes. Stable structural classes only: `fn`, `fn-body`, `footnotes` — not typography utilities. This is the sole options exception.

  *Done when:* DESIGN describes `.list` vs `.both`, default `.list`, id ownership, the defaulted parameter, and that footnotes are new HTML (not matching current output).

## Phase 2 — Implementation

- [ ] **`feat: emit list or list+near footnotes`**

  First implement GFM list footnotes (`.list`): references and definitions become `sup.fn` + `section.footnotes` as in the contract. Then implement `.both` by cloning each definition’s text into `<span class="fn-body" hidden aria-hidden="true">` under that `sup`. Documents with no footnotes are unchanged. Cover no-footnotes, `.list`, `.both`, missing definitions, and id/aria invariants in parser tests. Update `CHANGELOG.md`. Tag a version consumers (e.g. rwagasore) can pin.

  *Done when:* `.list` emits GFM footnote HTML from `[^id]` source; both modes are tested; default remains `.list`; a tagged version exists.

## Out of scope

- Viewport / sidebar / popover placement (consumer CSS).
- Mutating the tree after parse to strip `hidden`.
- Additional parse knobs beyond `FootnoteHtml`.
- Typography or utility classes on Markdown tags.

## Ordering and parallelism

- Phase 1 is the normative prerequisite for Phase 2.
- Do not tick a task until its change has merged.
