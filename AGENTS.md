# AGENTS — ztree-parse-md

Operating rules for humans + AI.

## Workflow

- Never commit to `main`/`master`.
- Always start on a new branch.
- Only push after the user approves.
- Merge via PR.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/).

- fix → patch
- feat → minor
- feat! / BREAKING CHANGE → major
- chore, docs, refactor, test, ci, style, perf → no version change

## Releases

- Semantic versioning.
- Versions derived from Conventional Commits.
- Release performed locally via `/create-release` (no CI required).
- Manifest (if present) is source of truth.
- Tags: vX.Y.Z

## Repo map

- `src/root.zig` — public API: re-exports `parse()` from the adapter
- `src/adapter.zig` — SAX-to-tree adapter: converts bun-md events into ztree `Node` tree (+ tests)
- `src/shim/bun.zig` — stdlib shim for bun-md's `@import("bun")` APIs
- `build.zig` — build config: wires bun-md dependency with shim injection
- `build.zig.zon` — dependencies: ztree, bun-md
- `DESIGN.md` — architecture: adapter pattern, memory model, tag mapping

## Merge strategy

- Prefer squash merge.
- PR title must be a valid Conventional Commit.

## Definition of done

- Works locally.
- Tests updated if behaviour changed.
- CHANGELOG updated when user-facing.
- No secrets committed.

## Orientation

- **Entry point**: `src/root.zig` — public `parse()` function
- **Domain**: GFM Markdown parser that produces a ztree `Node` tree (arena-allocated)
- **Backend**: [bun-md](https://github.com/erwagasore/bun-md) — Zig port of md4c, CommonMark 0.31.2 + GFM
- **Language**: Zig (0.16-dev)
