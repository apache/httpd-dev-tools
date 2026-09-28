---
name: backport
description: Propose a backport of trunk revisions to 2.4.x - cherry-pick each rev into its own commit on a new branch and worktree off origin/2.4.x, build it, and open a "[2.4.x] Merge ..." PR after previewing the text, then draft its STATUS entry. Use for "backport r1234567 to 2.4.x", "propose a backport of <hash>", "/backport mod_ssl r1934975 r1934980".
---

# Propose a trunk → 2.4.x backport

Given one or more trunk revisions, build a `2.4.x-<topic>` branch off `origin/2.4.x` with
**one commit per trunk revision**, build it, and open a PR against `2.4.x` whose body
quotes the trunk commit messages.

Usage: `/backport <topic> r1234567 [r2345678 | <githash> ...]`. Revisions may be given as
svn revs or trunk git hashes. `<topic>` names the branch and fills the PR subject (e.g.
`mod_ssl`, `mod_proxy_http`); if it is not given, pick one from the files touched and say
so.

## 0. Preflight

- If the checkout has an `AGENTS.md`, read it first and follow it. Local guidance there
  (paths, build setup, commit and PR conventions) takes precedence over the defaults in
  this skill.
- `git fetch origin`. Base on **`origin/2.4.x`**; local `trunk`/`2.4.x` are stale.
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

Record **both** the git hash and the svn revision for every commit.

- Rev → hash (the trailing space stops r123 matching r1234):
  ```
  git log origin/trunk --format='%H %s' --grep='trunk@1234567 '
  ```
  It must resolve to exactly one commit.
- Hash → rev:
  ```
  git show <hash> --no-patch --format=%b | grep -o 'trunk@[0-9]*'
  ```
- Confirm each is on trunk: `git merge-base --is-ancestor <hash> origin/trunk`.
- Order them oldest first (trunk order), whatever order they were given in.

Check whether any is already in 2.4.x. The repo is mirrored from svn, where a backport is
a fresh commit, so `git cherry` and `git branch --contains` say nothing; grep the
`origin/2.4.x` log for the rev (`git log origin/2.4.x --grep='r1234567'`) and compare the
code itself.

Print a table and confirm it with the user before going further:

| rev | hash | subject |
| --- | --- | --- |
| r1234567 | 0123456789 | ... |

## 2. Branch, worktree, configure

Branch `2.4.x-<topic>`; worktree under `.claude/worktrees/` with a name of **7 characters
or fewer**, e.g. `bpssl`. The `test/modules/arch/linux` suite binds a unix socket under
the worktree path, which has to fit the 108-byte `sockaddr_un` limit:

```
git worktree add -b 2.4.x-<topic> .claude/worktrees/<name> origin/2.4.x
```

In the worktree (a fresh worktree has no `config.nice`):

```
./buildconf --with-apr=<APR source tree>
./configure --enable-maintainer-mode --with-ssl --enable-reduced-exports \
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

Then rewrite the message with `git commit --amend -F <file>` (file in the scratchpad):
the trunk message is kept **as-is**, except the `git-svn-id:` line is removed and the end
of the message becomes:

```
Merge r1234567 from trunk.
(cherry picked from commit <full hash>)
```

Trunk trailers (`Submitted by:`, `PR:`, `Github:` etc.) stay where they were, above those
two lines. No `Co-Authored-By` trailer for a clean pick: the change is the trunk
author's. Never a `Claude-Session` trailer.

**Always exclude `docs/log-message-tags/`**: it is maintained only on trunk. Drop any
change to it from the pick (`git rm -f` a file the pick adds, `git checkout HEAD --` one
it modifies) before committing; the `APLOGNO()` numbers in the code are allocated on trunk
and are backported unchanged. No omission note is needed for this.

Conflicts:

- Resolve against the 2.4.x code, which differs in APIs, MMN and surrounding context. Read
  the 2.4.x function before editing; don't force the trunk hunk in.
- A `CHANGES` hunk should not be carried; bring the trunk `changes-entries/*.txt` file if
  the rev has one.
- If a rev depends on an earlier trunk rev not in the list, **stop** and report it,
  suggesting that rev be added, rather than writing the missing code.
- Note a resolved conflict in that commit, as a line above the `Merge` line:
  `[conflicts resolved in path/to/file.c]`. Add `Co-Authored-By` only if the resolution
  was substantive. Flag it in the report and the PR body.

Omitted files: if the user asks for code only, or a rev's test files don't exist on 2.4.x,
drop those hunks (`git rm -f` / `git checkout HEAD --`). Then remove the `* docs/...` and
`* test/...` bullet paragraphs for them from the message, and add no omission note: the
message describes only what the commit contains.

## 4. Build

From the top level of the worktree:

```
make -j$(nproc)
```

Never `make -C modules/<dir>`: it leaves the `.so` stale. Treat a new compiler warning in
the touched files as a failure. Report any failure verbatim, fix it (a backport-specific
fix goes in that rev's commit, noted as a conflict resolution) and rebuild.

Offer, but don't run by default, `make check-pytest PYTEST_DIRS=test/modules/<pkg>` for
the affected area.

## 5. Push, preview the PR, then create it

Push to the user's fork (`<fork-remote>` from step 0) with an **explicit refspec** (a
bare push resolves to the tracked branch). Never push to `origin`:

```
git push <fork-remote> 2.4.x-<topic>:2.4.x-<topic>
```

Draft the PR:

- Subject: `[2.4.x] Merge changes to <topic>`
- Body: a `Merge ... from trunk:` line, then each trunk message inline-quoted (every line
  prefixed with `> `, `git-svn-id:` line removed), a blank line between them:

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

## 6. STATUS entry

Once the PR exists, give the user an entry to paste into the 2.4.x `STATUS` file, under
`PATCHES PROPOSED TO BACKPORT FROM TRUNK:`. Output it only; do not edit or commit
`STATUS`. The shape, 2-space indent for `*)`, 5 for the fields, continuation URLs aligned
under the first:

```
  *) mod_foo: One-line CHANGES-style summary of what the backport does.
     trunk patch: https://svn.apache.org/r1234567
                  https://svn.apache.org/r2345678
     2.4.x patch: https://github.com/apache/httpd/pull/NNN.patch
     +1:
```

- One `https://svn.apache.org/rNNN` line per revision on the branch, in trunk order,
  including any added later (dependencies, follow-up fixes).
- The summary uses the same prefix a CHANGES entry would (`mod_foo:`, `core:`), written
  for a voter, not a list of the commit subjects.
- **The `+1:` line MUST be empty**: `     +1:` with nothing after it, not even a trailing
  space. Votes are added by the committers themselves.

Then offer to copy the entry to the clipboard. On a yes, write it to a file in the
scratchpad and use whichever tool the session has a display for:

```
if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null; then wl-copy < <file>
elif [ -n "$DISPLAY" ] && command -v xclip >/dev/null; then xclip -selection clipboard < <file>
elif command -v pbcopy >/dev/null; then pbcopy < <file>
fi
```

If none applies (e.g. an SSH session), say so and leave the entry in the reply to copy by
hand. Check the file has no trailing whitespace (`grep -n ' $' <file>` finds nothing)
before copying.

## Notes

- Keep a running record at `.claude/sessions/backport-<topic>-session.md` in the main
  checkout (not the worktree, which gets removed), appended as work happens. Leave it
  untracked.
- A follow-up to a pushed PR is a new commit, never a force-push without explicit
  confirmation.
