---
name: merge-backport
description: Squash-merge an approved 2.4.x backport PR - check the PR targets 2.4.x and CI is green, build a squash commit message from the PR's commit messages plus Submitted by / Reviewed by / Co-Authored-By / GitHub trailers, preview it, and merge only once the user approves. Use for "merge backport PR 1092", "squash-merge PR NNN into 2.4.x", "/merge-backport 1092".
---

# Squash-merge a 2.4.x backport PR

Given a PR number, check that the PR is for `2.4.x` and that CI passed, build the
squash commit message, **show it to the user**, and merge only after they approve it.

Usage: `/merge-backport <PR number>`. Below, `N` is that number. Every `gh` command
takes `-R apache/httpd`.

Each "stop" below means: do not merge, report what was found, and end there. Never
work round a failed check (no `--admin`, no `--auto`, no waiting for CI to finish).

## 0. Preflight

- If the checkout has an `AGENTS.md`, read it first and follow it. Local guidance there
  takes precedence over the defaults in this skill.
- Find the apache/httpd remote, `$UP`: `upstream` when the checkout has both an `origin`
  and an `upstream` remote (the usual triangle: `origin` is the user's fork), else
  `origin`. Check that it really points at apache/httpd:
  ```
  if git remote | grep -qx upstream && git remote | grep -qx origin; then UP=upstream; else UP=origin; fi
  git remote get-url $UP | grep -q '[:/]apache/httpd\(\.git\)\?$' || echo "$UP is not apache/httpd"
  ```
  If it isn't, ask the user which remote is apache/httpd. Below, `$UP` is that remote.
- `git fetch $UP`.

## 1. Verify the PR

```
gh pr view N -R apache/httpd --json number,title,baseRefName,state,isDraft,mergeable,mergeStateStatus,headRefOid,commits,reviews,latestReviews
```

Stop unless all of these hold:

- `baseRefName` is exactly `2.4.x`. A PR for `trunk` or any other branch is not a
  backport; do not offer to merge it anyway.
- `state` is `OPEN` and `isDraft` is false.
- `mergeable` is `MERGEABLE`. `CONFLICTING` means the branch needs rebasing, which is
  not this skill's job. `UNKNOWN` means GitHub has not computed it yet: ask again once
  after a few seconds, then stop if it is still unknown.

Record `headRefOid` as `HEAD_SHA`. Everything checked from here on is about that
commit, and step 6 merges only that commit.

## 2. Verify CI is green

```
gh pr checks N -R apache/httpd --json name,state,bucket,workflow
```

Green means there is **at least one** check and every check's `bucket` is `pass` or
`skipping`. Otherwise stop:

- any `fail` or `cancel`: list those checks by workflow and name;
- any `pending`: CI is still running. Say so; do not wait or poll;
- no checks at all: CI never ran (a `[skip ci]` on the branch, or workflows awaiting
  approval), which is not green.

## 3. Collect the commits

```
git fetch $UP pull/N/head
git rev-parse FETCH_HEAD        # must equal HEAD_SHA; if not, start again from step 1
git rev-list --reverse $UP/2.4.x..$HEAD_SHA
```

That list, oldest first, is the PR's commits. Its length must match the number of
`commits` step 1 reported; stop if it does not.

## 4. Build the commit message

Write the body to a file in the scratchpad directory.

**Subject:** `<PR title> (#N)`, with the `[2.4.x]` tag stripped from the title: the
commit is on 2.4.x, so the tag says nothing there. `[2.4.x] Merge changes to mod_dav`
becomes `Merge changes to mod_dav (#N)`. Strip it from the end of the title too, where
some PRs put it, along with the space beside it.

**Body:** the full message of each commit, in order, with one blank line between them:

```
git show -s --format=%B <hash>
```

Copy each message as it is: its `git-svn-id:` line, its `(cherry picked from commit
...)` line and any other trailers (`Reviewed by:`, `Suggested by:` etc.) all stay
where they are. These are removed:

- every `Co-Authored-By:` line (any capitalisation);
- every `Submitted by:` line (any capitalisation, `Submitted-by:` too), with any
  continuation line where a long list of names was wrapped;
- every `PR:` line, the Bugzilla references;
- every `GitHub:` line (any capitalisation; `Github:` is common);

  Collect all four kinds first, noting which commit each came from: they are gathered
  into the trailers at the end of the message, below, and appear nowhere else. Take
  out the lines only, and a blank line they leave doubled; a message must not end up
  with two blank lines in a row or a trailing one.
- `[skip ci]`, wherever it appears (along with a line left empty by it), since it
  would skip CI for the merge commit on 2.4.x.

Check none are left in the bodies before adding the trailers:

```
grep -n -i -e '^co-authored-by:' -e '^submitted[ -]by:' -e '^PR:' -e '^github:' -e 'skip ci' <file>      # must print nothing
```

**Trailers:** after the last message, a blank line, then two paragraphs in this order:

```
Submitted by: abernal, Some Person <some.person example.com>
Reviewed by: covener, rpluem

PR: 70264, 69592
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
GitHub: closes #465, closes #309, #N
```

The layout matters, because git and GitHub each parse only the last paragraph of the
message as trailers, and both are easily put off:

- `Submitted by:` and `Reviewed by:` have a space in the key, so git does not accept
  them as trailers, and one such line in the last paragraph makes git ignore every
  trailer in it. They therefore get a paragraph of their own, above the real trailers.
- The message ends with the `GitHub:` line and a single newline. **No blank line after it**:
  with trailing blank lines GitHub credits no co-authors at all. Strip them and check
  that git sees the trailers:
  ```
  printf '%s\n' "$(cat <file>)" > <file>.new && mv <file>.new <file>
  git interpret-trailers --parse < <file>     # must print the PR, Co-Authored-By and GitHub lines
  grep -c -i '^submitted[ -]by:' <file>       # must print 1
  grep -c -i -e '^PR:' <file>; grep -c -i '^github:' <file>     # 1 (or 0 for PR:) and 1
  ```
- No blank line inside the last paragraph, and nothing but trailers in it.

- `Submitted by:` names, each once and comma-separated on one line, the git author of
  every commit:
  ```
  git log --reverse --format='%an <%ae>' $UP/2.4.x..$HEAD_SHA
  ```
  together with everyone named in a `Submitted by:` line removed from the bodies. Go
  through the commits in order, taking each commit's git author and then the names
  from its own `Submitted by:` line, which may itself be a comma-separated list.
  Names from a removed line are kept as written there, apart from making them
  consistent with the **Names** rules below, so that one person given as `jdoe` in
  one commit and `Jane Doe <jdoe apache.org>` in another is listed once.

  Besides those, only commit **authors** go here. The user doing the merge is named only if they
  are the author of at least one commit; never add them for opening the PR, for
  being the committer of a cherry-pick (`%cn`), or for doing the merge.
- `Reviewed by:` names everyone whose **latest** review is `APPROVED`
  (`latestReviews`) and whose `authorAssociation` is `MEMBER` or `OWNER`, i.e. a
  committer. An approval from anyone else is mentioned in the preview and left out of
  the trailer. If no committer has approved, stop: the backport is not reviewed.
- `Co-Authored-By:` lists every co-author named in the commits, each once (compare
  name and email together: different models share one `noreply` address), in order
  of first appearance, **one per line**. Never join them with commas: GitHub reads
  such a line as a single author with a garbled name.
  ```
  git log --reverse --format=%B $UP/2.4.x..$HEAD_SHA | grep -i '^co-authored-by:'
  ```
  Write the key as `Co-Authored-By:` whatever capitalisation the commit used. Leave
  out anyone already named in `Submitted by:`, and omit the lines if there are none.
  Never add a co-author who is not in the commits, yourself included: this skill
  writes the message, not the change.
- `PR:` lists every Bugzilla number from the `PR:` lines removed from the bodies, each
  once, in order of first appearance, comma-separated on one line: `PR: 70264, 69592`.
  Numbers only. Omit the line if no commit had one. Don't go looking for bug numbers
  mentioned elsewhere in the text; only `PR:` lines count.
- `GitHub:` lists every reference from the `GitHub:` lines removed from the bodies,
  each once, in order of first appearance, and then `#N` for this PR, comma-separated
  on one line. Keep each reference as the commit wrote it, `closes #465` staying
  `closes #465`; a line naming several (`closes #143, closes #760`) gives several. If
  a commit already names `#N`, it is not repeated. The line is always present, since
  it always has at least `#N`, and is always the last line.

**Names.** A committer is written as their Apache userid alone; anyone else as their
name plus obfuscated email, `@` replaced by a space: `Some Person <some.person
example.com>`.

- An author whose email is `<id>@apache.org` is the committer `<id>`.
- A reviewer is known only by GitHub login. Find the userid from the email on their
  commits:
  ```
  gh api 'repos/apache/httpd/commits?author=<login>&per_page=5' --jq '.[].commit.author.email'
  ```
  An `<id>@apache.org` address there gives the userid. If there is none, write the
  GitHub login and flag it in the preview for the user to correct. Never guess a
  userid from a login or a name.

## 5. Preview, and wait for approval

Show the user:

- the PR number, title and `HEAD_SHA`;
- the check summary (how many passed, how many skipped);
- the commits, one line each;
- anything that needs their attention: a reviewer whose userid could not be found, an
  approval left out for not being a committer's, an approval given on a commit older
  than `HEAD_SHA` (compare `reviews[].commit.oid`), a `[skip ci]` that was removed;
- the subject and the complete body, verbatim, in a fenced block.

Then **stop and wait**. Merge only on an explicit go-ahead for this message. If they
ask for changes, make them and show the whole message again. Approval of one PR's
message never carries over to another PR, or to a message that has since changed.

## 6. Merge

```
gh pr merge N -R apache/httpd --squash --match-head-commit $HEAD_SHA \
    --subject "$SUBJECT" --body-file <scratchpad file>
```

`--match-head-commit` makes GitHub refuse if the branch has moved since it was
checked. If it does refuse, start again from step 1 with the new head; do not retry
without the flag. Don't pass `--delete-branch`: the branch is the contributor's.

Afterwards:

```
git fetch $UP
git log -1 --format='%H%n%B' $UP/2.4.x
```

Report the new commit hash, and compare its message with the approved one: say so if
GitHub changed anything (it sometimes appends `Co-authored-by:` lines of its own).

## Notes

- The merge goes through `gh pr merge` only. Never push to `$UP/2.4.x` directly,
  and never do the squash locally.
- One PR per invocation. For several PRs, run the whole sequence, preview included,
  for each.
