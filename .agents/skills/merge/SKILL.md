---
name: merge
description: >-
  Commit any dirty tree via /commit, run newly added Swift tests and all
  scripts/*-probe.sh harnesses, then squash-merge the open PR and update local
  main. Use when the user types /merge, or asks to squash-merge, land, or merge
  the PR after tests.
disable-model-invocation: true
---

# Merge the PR (squash)

From the **repo root**, get a clean pushed branch, gate on new Swift tests +
harnesses, then squash-merge the PR onto the default branch.

## Workflow

1. **Dirty tree → `/commit` first**
   - Run `git status`.
   - If there are staged, unstaged, or untracked changes (anything that would
     appear in `git status --porcelain`), **read and follow** the personal
     commit skill at `~/.cursor/skills/commit/SKILL.md` end-to-end (settle
     other chats, typecheck/lint/review as that skill requires, commit, push,
     ensure/refresh the PR, Notion sync).
   - If the working tree is already clean but the branch is ahead of its
     remote, push (`git push` or `git push -u origin HEAD` if needed).
   - If clean and fully pushed, continue.

2. **Resolve PR + base**
   - Current branch: `git branch --show-current`.
   - If on the default branch (`main` / `master`), **stop** — nothing to merge.
   - Ensure a PR exists for this head:
     `gh pr view --json url,number,title,baseRefName,headRefName,mergeable,mergeStateStatus`.
   - If none: follow the commit skill’s “ensure a pull request exists” step
     (create one), then re-fetch PR metadata.
   - Base ref = PR `baseRefName` (usually `main`). Fetch it:
     `git fetch origin "<base>"`.

3. **Newly added Swift tests**
   - Collect Swift test sources **added** on this branch vs the PR base,
     including anything just committed in step 1:

     ```bash
     base="$(gh pr view --json baseRefName -q .baseRefName)"
     git fetch origin "$base"
     git diff --name-only --diff-filter=A "origin/${base}...HEAD" -- 'Tests/**/*.swift'
     ```

   - If that list is **empty**, print that there are no newly added Swift
     tests and continue (do **not** fail).
   - If non-empty:
     - Run those tests only. Prefer filtering by XCTest case type name
       derived from each file’s `final class Foo: XCTestCase` /
       `class Foo: XCTestCase` (or Swift Testing `@Suite` name if present):

       ```bash
       swift test --filter '<TypeName>'
       ```

       Run one `swift test --filter` per new type, or a single invocation
       with multiple `--filter` flags if that is simpler. Do **not** silently
       fall back to the entire suite unless every new file lacks a detectable
       test type name — in that case run `swift test` and say so.
     - On failure: **stop**. Do not merge. Report the failing filter/command
       and the relevant log tail.

4. **Harness tests**
   - Run every probe harness script that exists:

     ```bash
     ./scripts/composer-probe.sh
     ```

     Also run any other `scripts/*-probe.sh` found via a directory listing
     (same pattern), each to completion.
   - Harnesses need a logged-in GUI session (real key window). Use an
     unrestricted shell.
   - On non-zero exit: **stop**. Do not merge. Report which script failed.

5. **Squash-merge the PR**
   - Re-check mergeability:
     `gh pr view --json mergeable,mergeStateStatus,url`.
   - If not mergeable / blocked / dirty behind base: **stop** and report
     status + URL. Do not force.
   - Merge:

     ```bash
     gh pr merge --squash --delete-branch
     ```

     Use the PR’s existing title/body as the squash commit metadata
     (`gh pr merge` defaults). Do **not** pass `--admin` unless the user
     explicitly asked to bypass checks.
   - Update local tree:

     ```bash
     git checkout "$base"
     git pull --ff-only origin "$base"
     git branch -d "<old-head>" 2>/dev/null || true
     ```

     (`--delete-branch` already removes the remote head; delete the local
     head branch if it still exists.)

6. **Confirm**
   - Report: whether `/commit` ran, which new Swift test filters ran (or
     “none”), harness results, squash-merge success, PR URL, and the new
     `HEAD` on the base branch (`git log -1 --oneline`).

## Notes

- Never squash-merge past failing new Swift tests or failing harnesses.
- Never `git push --force` or `gh pr merge --admin` unless the user
  explicitly asks.
- “Newly added” means `diff-filter=A` vs the PR base — not every test that
  was merely modified. Modified-only tests are out of scope for this skill.
- The composer harness is DEBUG-only and opens a short-lived window; that is
  expected.
- If the commit skill stops to ask the user (ambiguous review finding,
  unsettled chats past timeout), wait for their answer before continuing
  merge steps.
