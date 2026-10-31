---
name: backport
description: Propose a backport of trunk revisions to 2.4.x - cherry-pick each rev into its own commit on a new branch and worktree off origin/2.4.x, build it, and open a "[2.4.x] Merge ..." PR after previewing the text. Use for "backport r1234567 to 2.4.x", "propose a backport of <hash>", "/backport mod_ssl r1934975 r1934980".
---

# Propose a trunk → 2.4.x backport

Given one or more trunk revisions, build a `2.4.x-<topic>` branch off `origin/2.4.x` with
**one commit per trunk revision**, build it, and open a PR against `2.4.x` whose body
quotes the trunk commit messages. The repository is now read/write Git: the PR is the
backport proposal, and no `STATUS` entry is needed.

Usage: `/backport <topic> r1234567 [r2345678 | <githash> ...]`. Revisions may be given as
svn revs or trunk git hashes; commits made since the move to Git have a hash only.
`<topic>` names the branch and fills the PR subject (e.g. `mod_ssl`, `mod_proxy_http`);
if it is not given, pick one from the files touched and say so.

## 0. Preflight

- If the checkout has an `AGENTS.md`, read it first and follow it. Local guidance there
  (paths, build setup, commit and PR conventions) takes precedence over the defaults in
  this skill.
- `git fetch origin`. Base on **`origin/2.4.x`**; local `trunk`/`2.4.x` may be stale.
- Stay inside this checkout. The only outside paths touched are the read-only APR source
  trees buildconf needs.
- Find the user's GitHub fork: their login, and the remote that pushes to
  `<login>/httpd`:
  ```
  FORK_OWNER=$(gh api user --jq .login)
  git remote -v | grep "[:/]$FORK_OWNER/httpd\(\.git\)\? (push)"
  ```
  The first column is `<fork-remote>`, used in step 5. If no remote matches, ask the user
  which remote is their fork; never fall back to `origin`.

## 1. Identify the trunk commits

Record the git hash for every commit, and its svn revision where it has one.

- Rev → hash (the trailing space stops r123 matching r1234):
  ```
  git log origin/trunk --format='%H %s' --grep='trunk@1234567 '
  ```
  It must resolve to exactly one commit.
- Hash → rev:
  ```
  git show <hash> --no-patch --format=%b | grep -o 'trunk@[0-9]*'
  ```
  No output means a post-svn commit: it has no revision, and is named by its hash (the
  first 10 characters) wherever this skill says `r<x>`.
- Confirm each is on trunk: `git merge-base --is-ancestor <hash> origin/trunk`.
- Order them oldest first (trunk order), whatever order they were given in.

Check whether any is already in 2.4.x. A backport is a fresh commit, so `git cherry` and
`git branch --contains` say nothing; grep the `origin/2.4.x` log for the rev and the hash
(`git log origin/2.4.x --grep='r1234567' --grep='<hash>'`; `cherry-pick -x` records the
hash) and compare the code itself.

Check too whether each rev's **test changes** are already on 2.4.x. `test/` is kept
identical on trunk and 2.4.x (`test/check-test-sync.sh`; see "Tests of changes missing
from 2.4.x" in `test/README.pytest`), so a trunk test usually reaches 2.4.x ahead of the
code it tests, carrying a `not_backported`/`skip_not_backported` mark naming the rev. For
each rev touching `test/`, find the marks naming it:

```
git grep -n -e 'not_backported' origin/2.4.x -- test | grep '<rev>'
```

A mark may name a range (`"r1937596-r1937647"`); check by eye whether a rev falls inside
one. Then compare the files the rev touches between the branches:

```
files=$(git diff-tree --no-commit-id --name-only -r <hash> -- test)
git diff --quiet origin/trunk origin/2.4.x -- $files && echo synced || echo 'not synced'
```

`synced` means 2.4.x has the rev's test changes (and any later trunk ones). On
`not synced`, read that diff: trunk may only have moved on since the last copy, in which
case the rev's hunks are still on 2.4.x. A reverse `git apply --check` of the rev's test
hunks is no help, as later trunk commits (adding the very mark, typically) change the
same lines.

Print a table and confirm it with the user before going further, including the test
state of each rev (`n/a`, `synced`, `not synced`) and the marks found:

| rev | hash | subject | tests |
| --- | --- | --- | --- |
| r1234567 | 0123456789 | ... | synced; 2 marks |

## 2. Branch, worktree, configure

Branch `2.4.x-<topic>`; worktree under `.claude/worktrees/`:

```
git worktree add -b 2.4.x-<topic> .claude/worktrees/<name> origin/2.4.x
```

In the worktree (a fresh worktree has no `config.nice`):

```
./buildconf --with-apr=<APR source tree>
./configure --enable-maintainer-mode --with-ssl \
    --enable-modules=reallyall --enable-mpms-shared=all
```

If the local guidance does not name the APR source tree, ask the user; apr-util is found
alongside it. Don't pass an `apr-1-config` path to `--with-apr`: that mode copies the
`.m4` files from `apr-config --installbuilddir`, where some distributions don't ship them.
**Never `make install`**.

## 3. Cherry-pick each revision into its own commit

In trunk order:

```
git cherry-pick -x <hash>
```

**A commit used exactly as-is** (it applies cleanly and nothing is dropped from it) keeps
the rest of the message `cherry-pick -x` gives it: the trunk message byte-for-byte, then
`(cherry picked from commit <full hash>)`.

**A commit that cannot be used as-is** (a conflict resolved, hunks or files omitted, a
backport-specific fix folded in) also opens with a prefix saying what differs:

```
Merge r1234567 from trunk (test/modules/arch/linux changes omitted):

<trunk message>
(cherry picked from commit <full hash>)
```

Keep the parenthesis brief: `conflicts resolved in modules/ssl/ssl_engine_io.c`, `docs changes
omitted`. Trunk trailers (`Submitted by:`, `PR:`, `GitHub:` etc.) stay where they were.
No `Co-Authored-By` trailer unless the change to the trunk commit was substantive. Never a
`Claude-Session` trailer.

**Always exclude `docs/log-message-tags/`**: it is maintained only on trunk. Drop any
change to it from the pick (`git rm -f` a file the pick adds, `git checkout HEAD --` one
it modifies) before committing; the `APLOGNO()` numbers in the code are allocated on trunk
and are backported unchanged. This alone does not count as a change to the commit: no
prefix is needed for it, though the pick must then be amended to commit without it.

Conflicts:

- Resolve against the 2.4.x code, which differs in APIs, MMN and surrounding context. Read
  the 2.4.x function before editing; don't force the trunk hunk in.
- A `CHANGES` hunk should not be carried; bring the trunk `changes-entries/*.txt` file if
  the rev has one.
- If a rev depends on an earlier trunk rev not in the list, **stop** and report it,
  suggesting that rev be added, rather than writing the missing code.
- A resolved conflict makes the commit one that cannot be used as-is: give it the
  `Merge r<x> from trunk (conflicts resolved in <file>):` prefix above, and flag it in the
  report and the PR body.

Omitted files: if the user asks for code only, or a rev's test files don't exist on 2.4.x,
drop those hunks (`git rm -f` / `git checkout HEAD --`), give the commit the prefix above
(`(docs and test changes omitted)`), and remove the `* docs/...` and `* test/...` bullet
paragraphs for them from the trunk message, so it describes only what the commit contains.

**Tests already synced**: if step 1 found a rev's `test/` changes already on 2.4.x, the
pick will conflict on them, or apply them a second time. Drop every `test/**` change from
it (`git checkout HEAD -- test`) so the 2.4.x copy stays exactly what was synced, and
treat it as omitted files: prefix `(test changes already on 2.4.x)` and remove its
`* test/...` bullets. If its test changes are only partly synced, stop and report rather
than merging them by hand.

## 3a. Record the backport in the `not_backported` marks

After the last pick, the 2.4.x build has the changes that the marks step 1 found are
waiting for. Left as they are, the marks would turn a regression into an expected failure,
or skip the test altogether. The marks stay in place, since older 2.4.x releases still
lack the change. Instead each one gets the release the backport will first appear in, per
`test/README.pytest`. That release is the version the 2.4.x tree is building now, `-dev`
suffix dropped:

```
git show origin/2.4.x:include/ap_release.h \
  | grep -E '#define AP_SERVER_(MAJOR|MINOR|PATCH)VERSION_NUMBER'
```

(e.g. `2.4.70`; a `-dev` server counts as that release). For each
`not_backported(...)` / `skip_not_backported(...)` naming a rev on the branch, add the
keyword argument after the existing ones, wherever the mark is applied (a decorator, a
`pytestmark = ...` line, a module-level `NOT_BACKPORTED = ...`, the `marks=` of a
`pytest.param`):

```
@not_backported("r1939033", "nonce-count validation", backported_in="2.4.70")
```

Change nothing else on the line. A mark naming a range or several revs, not all of which
are on the branch, keeps no `backported_in`: flag it in the report instead. Never touch a
mark for a rev not on the branch.

`test/` is edited on trunk and copied to 2.4.x, so this edit belongs on trunk too, and
both branches must end up byte-identical under `test/`. Make it **once**, as one commit in
the repo's ChangeLog style with the `Co-Authored-By` trailer:

```
* test/modules/aaa/test_003_nccheck.py (TestNcCheck.test_digest_001,
  TestNcCheck.test_digest_002): Mark as backported in 2.4.70.
```

- Commit it on the backport branch, after the picks.
- Cherry-pick the same commit onto a branch `trunk-<topic>-bp` off `origin/trunk`, in a
  second worktree under `.claude/worktrees/`. It must apply cleanly there. If trunk's copy
  of the file has moved on, stop and report instead of resolving it.
- Check that `git diff <backport branch> trunk-<topic>-bp -- <the edited files>` is
  empty. Then ask the user how the trunk side should land: committed to trunk directly,
  or a PR (preview its text first, as in step 5). Don't push it unasked.

## 4. Build

From the top level of the worktree:

```
make -j$(nproc)
```

Never `make -C modules/<dir>`: it leaves the `.so` stale. Treat a new compiler warning in
the touched files as a failure. Report any failure verbatim, fix it (a backport-specific
fix goes in that rev's commit, noted as a conflict resolution) and rebuild.

If step 3a edited any marks, run the tests that carried them against this build
(`make check-pytest PYTEST_DIRS=<dirs>`, per the local guidance). They must pass, not
XPASS or skip; a failure means the backport is incomplete, so report it and stop.

## 5. Push, preview the PR, then create it

Push to the user's fork (`<fork-remote>` from step 0) with an **explicit refspec** (a
bare push resolves to the tracked branch). Never push to `origin`:

```
git push <fork-remote> 2.4.x-<topic>:2.4.x-<topic>
```

Draft the PR:

- Subject: `[2.4.x] Merge changes to <topic>`
- Body: a `Merge ... from trunk:` line, then each trunk message inline-quoted (every line
  prefixed with `> `), a blank line between them. Take each revision from the trunk
  commit named in its `(cherry picked from commit ...)` line (`git-svn-id: ...trunk@NNN`
  there; a post-svn commit is listed by its 10-character hash instead). Quote the trunk
  message only: drop the `(cherry picked from ...)` line and any `Merge r...` prefix,
  whose explanation belongs in a note instead. The marks commit from step 3a is not
  quoted; mention it in one line after the quotes, with a link to the trunk side once it
  exists:

  ```
  Merge r1234567, r2345678 from trunk:

  > * modules/ssl/ssl_engine_io.c (foo): Do the thing.
  >
  > Submitted by: ...

  > * modules/ssl/ssl_engine_kernel.c (bar): Do the other thing.

  🤖 Generated with [Claude Code](https://claude.com/claude-code)
  ```

  The quoted messages keep their original line breaks; they are quotes. Any prose
  written for the PR (e.g. a conflict note) is one line per paragraph, not hard-wrapped:
  GitHub reflows Markdown to the reader's width.

**Show the subject and body to the user and wait for approval.** Only then:

```
gh pr create --repo apache/httpd --base 2.4.x --head $FORK_OWNER:2.4.x-<topic> \
    --title '[2.4.x] Merge changes to <topic>' --body-file <scratchpad file>
```

Report the PR URL. Leave the worktree in place for follow-ups and give the command to
remove it: `git worktree remove .claude/worktrees/<name>`.

## Notes

- Keep a running record at `.claude/sessions/backport-<topic>-session.md` in the main
  checkout (not the worktree, which gets removed), appended as work happens. Leave it
  untracked.
- A follow-up to a pushed PR is a new commit, never a force-push without explicit
  confirmation.
