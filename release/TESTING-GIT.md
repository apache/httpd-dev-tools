# Testing the git backend before cutover

The release scripts drive the httpd source repository through svn or git,
depending on whether they run from a svn working copy or a git clone. This
document is the checklist for exercising
the git backend against a personal fork while the project is still on svn.
Nothing here touches `apache/httpd`, `dist.apache.org` or the `pmc`
repository. See `README.md` for the normal release procedure and
`GIT-MIGRATION-PLAN.md` for the design.

## 1. What a rehearsal does and does not touch

| Repository | During a rehearsal |
|---|---|
| your fork of `apache/httpd` | candidate branches pushed and deleted, release tag pushed, "publishing release" commit pushed to `2.4.x` |
| your fork of `apache/httpd-site` | cloned, committed locally, **not** pushed |
| `dist.apache.org` | read-only `svn export` of `dev/httpd` and `release/httpd` to seed `dist/apache.org-dist` |
| `pmc` (private) | read-only `svn export` of `pmc/httpd` to seed `dist/pmc` (needs your pmc access) |
| `docs-build`, APR tags | read-only svn checkouts/exports, as in a real release |
| GitHub Actions on your fork | runs on each candidate branch push and on the release tag |

The source repository is the URL of the clone's `origin` remote
(`GIT_SRC_REMOTE`); each script prints it as `source repository: ...`.
`DIST_MODE=local` is implied as soon as the scripts run from a git clone and
that repository is not `apache/httpd`. Every script prints
`DIST_MODE=local (implied by fork ...): nothing will be committed to dist.apache.org or pmc`
at start. If you do not see that line, stop.

## 2. Prerequisites

1. A fork of <https://github.com/apache/httpd> with the `2.4.x` branch, and
   a fork of <https://github.com/apache/httpd-site>. Enable Actions on the
   httpd fork if you want to watch CI.
2. Push access to both forks: an ssh key for `git@github.com:` URLs, or
   `gh auth login` plus `gh auth setup-git` for https URLs.
3. `svn` with access to `pmc` (for the read-only seed), `git` 2.x, `jq`,
   `curl`, `perl`, autotools and libtool (r1 runs `buildconf`), the docs
   build toolchain (r0 rebuilds `docs/manual`), gpg with your key (r1 signs).
   `gh` is optional.
4. A fresh clone to run from:

   ```
   git clone -b 2.4.x git@github.com:<you>/httpd.git ~/asf/httpd-2.4.x-rehearsal
   cd ~/asf/httpd-2.4.x-rehearsal
   git config user.email <you>@apache.org
   ```

   Build it once so `buildconf` dependencies are known to work. The scripts
   check the rest at start (clean tree, `HEAD` pushed, identity, push
   access) and tell you what to fix. `origin` must be the fork: if your
   everyday clone has `origin` = `apache/httpd` and the fork under another
   name, run with `GIT_SRC_REMOTE=<that name>` or use a dedicated clone.

5. Environment, exported once in the shell you run the scripts from:

   ```
   export DEV_TOOLS=~/asf/dev-tools
   # SCM=git is detected from the clone's .git and GIT_SRC_URL from its
   # 'origin' remote (the fork); neither needs to be set
   export GIT_SITE_URL=git@github.com:<you>/httpd-site.git
   export PROJECT=httpd            # only needed if the fork is not named httpd
   # DIST_MODE=local is implied; do not set DIST_MODE=svn
   ```

## 3. The run

Pick a version that does not exist as a tag on your fork yet. The current
`AP_SERVER_PATCHLEVEL_NUMBER` of the branch is the natural choice.

| Step | Command | Check afterwards |
|---|---|---|
| 0 | `rm -rf dist` | clean start; this also removes the local dist/pmc seed |
| 1 | `$DEV_TOOLS/release/r0-make-candidate.sh rc1` | summary shows `SCM: git`, `SOURCE: 2.4.x@<sha>`; on the fork: `git ls-remote $GIT_SRC_URL refs/heads/2.4.NN-rc1-candidate` exists and is one commit ("Post 2.4.NN-rc1 tag updates") ahead of your `2.4.x`; CI started; `dist/pmc/SECURITY/httpd-2.4.NN-rc1/` was created locally and *not* committed; `dist/VERSION` has `scm="git"` and `dist_mode="local"` |
| 2 | `$DEV_TOOLS/release/r1-make-tars.sh` | `dist/httpd-2.4.NN-rc1.tar.{gz,bz2}` plus `-deps`, `.sha256/.sha512`, `.asc`; the export came from the server branch, not your clone; compare the file list with a real svn-built tarball (section 4) |
| 3 | `$DEV_TOOLS/release/r2-prep-vote.sh` | `dist/apache.org-dist/dev/httpd/` holds the tars and `CHANGES_*`; commit step prints `local mode: not committing`; `dist/mail-vote-*.txt` names the fork URL and the commit sha |
| 4 | `$DEV_TOOLS/release/reset-candidate.sh` | "release already tagged" guard passes; candidate branch is gone from the fork; `dist/` removed; your `2.4.x` on the fork is untouched |
| 5 | repeat 1 to 3 with `rc2` | same checks; the rc1 commit is now unreachable on the fork, which is expected |
| 6 | `$DEV_TOOLS/release/r3-push-release-tars.sh` | local dev to release moves and `-rc2` renames done; commit prompt skipped; tag `2.4.NN` exists on the fork as an annotated tag pointing at the candidate's last commit (`git cat-file -p 2.4.NN`); candidate branch deleted; CI runs once more for the tag |
| 7 | `$DEV_TOOLS/release/r4-stage-release.sh` | CHANGES moved and CVEs folded in from the local pmc copy; `dist/site` edited; your clone has uncommitted next-version edits (`git diff` on `CHANGES`, `STATUS`, `include/ap_release.h`, `docs/`); the review output is `diff -rq` against `dist/local-dist-mode-seed` |
| 8 | `$DEV_TOOLS/release/r5-commit-staged-release.sh` | dist and pmc commits print as skipped; "publishing release httpd-2.4.NN" lands on the fork's `2.4.x`; site commit made locally, push skipped |
| 9 | `$DEV_TOOLS/release/r6-announce.sh -u <asf-id>` | CDN check skipped with a warning; `dist/mail_announce_*` generated |
| 10 | `$DEV_TOOLS/release/reset-candidate.sh` | must refuse: "release already tagged as 2.4.NN" |

The final ref graph on the fork should look like this, with the tag one
commit off the branch and no candidate branch left:

```
2.4.x:   A --- G        (G = "publishing release httpd-2.4.NN")
          \
           E            (tag 2.4.NN, "Post 2.4.NN-rc2 tag updates")
```

Afterwards, or whenever a rehearsal went past the point `reset-candidate.sh`
accepts (it refuses once the release tag exists), clean the fork with

```
$DEV_TOOLS/release/reset-fork.sh 2.4.NN
```

It refuses unless the source repository is a fork, then deletes the release
tag and every `2.4.NN-*-candidate` branch on the fork, force-pushes the
fork's `2.4.x` back to upstream (`GIT_UPSTREAM_URL`, default the github.com
`apache/httpd`) if the rehearsal pushed commits to it, resets the local
clone to the same point and removes `dist/`. Each step is confirmed
separately; `-k` leaves the clone and `dist/` alone. Deleting tags and force
pushing is fine on a fork; the release scripts never do either anywhere.

Also worth trying once each:

- rerun `r0 rc1` while the rc1 candidate exists: it warns, pulls the
  candidate clone, and pushes nothing new if nothing changed.
- rerun `r3` after step 6: it fails on the existing tag instead of
  overwriting it.
- commit something locally without pushing, then run any script: it fails
  with "has commits that are not on ...".
- run a step with `DIST_MODE=svn` set: it is refused for a fork.
- run `r5` after someone pushed to the fork's `2.4.x` in the meantime: the
  `--ff-only --autostash` pull must either fast-forward under the staged
  edits or stop with instructions, never merge.

## 4. Tarball equivalence (go/no-go for the export path)

After `r1`, compare the candidate tarball with the last published release:

```
$DEV_TOOLS/release/compare-tarballs.sh \
    https://dist.apache.org/repos/dist/release/httpd/httpd-2.4.69.tar.gz \
    dist/httpd-2.4.70.tar.gz
```

The script unpacks both, sorts every difference into "needs scrutiny" and
"expected release to release", and exits 2 when the first group is not
empty. It uses svn (read only) to tell files added or removed upstream
since the old release from files the export lost or invented, to confirm
the svn properties behind keyword and line-ending findings, and to tie
changed generated docs pages to the docs/manual commits behind them.
`-S` skips the svn lookups, `-v` lists every file, `-d` prints diffs for
the scrutiny items, `-w DIR` keeps the unpacked trees.

Expected on a git-built tarball today, matching section 5:

- empty directories present in svn and in the old tarball but absent from
  the candidate (`changes-entries`, some test fixture directories);
- `ROADMAP`, `VERSIONING` and `support/ab.c` differing only by svn keyword
  expansion.

Anything else in the scrutiny section is a finding.

## 5. Open issues to look out for

Known, by design or waiting for a project decision:

1. **svn keyword expansion.** `support/ab.c` has `svn:keywords Revision`;
   the svn tarball contains `$Revision: NNN $`, a git export contains
   `$Revision$`, so `ab -V` prints `<$Revision$>`. `ROADMAP` and
   `VERSIONING` carry `$Date$`/`$LastChangedDate$`. Decision needed: fix
   upstream (`ab.c` already prints `AP_AB_BASEREVISION`) or rewrite during
   export in git mode. Section 4 will list every affected file.
2. **Empty directories.** git does not track them, svn does. If the svn
   tree ships any empty directory the git-built tarball lacks it. Section 4
   shows this as "Only in svn".
3. **`svn:eol-style` CRLF files** (win32 `.dsp`, `.mak` etc.) should come out
   of the mirror byte-identical. Confirm in section 4.
4. **`dist/` is not in httpd's `.gitignore`**, only in svn:ignore. The git
   backend excludes it in the clean-checkout check; adding `/dist` upstream
   is the clean fix.
5. **Branch and tag protection.** Candidate branch deletion must not be
   blocked once this runs on `apache/httpd`: check `.asf.yaml`
   `protected_branches` patterns against `*-candidate`. Release tags are
   only ever created, so `protected_tags` is not a problem. Confirm with
   Infra; a fork cannot test this.
6. **Mirror direction at cutover.** While the svn to git mirror runs, a git
   mode release is not mirrored back into svn. The project has to decide
   which side is authoritative before the RM starts releasing from a git
   clone; nothing in the scripts enforces that decision.
7. **Historic candidate tags.** The mirror left tags such as
   `2.4.65-rc1-candidate`. New candidates are branches with new names so
   they never collide, but anyone who fetches both a tag and a branch of the
   same name gets git's "refname is ambiguous" warning. The alternative
   `candidate/${FULL_VERSION}` naming is a one-line change in
   `common-lib.sh` (`CANDIDATE_TAG`) if preferred.
8. **Signed release tags.** `GIT_SIGN_TAGS=1` is the default, so `r3`
   creates the release tag with `git tag -s`. `r0` and `r3` check first
   that signing works by creating and deleting a throwaway signed tag, which
   prompts for the passphrase like r1 does. The key is git's choice:
   `user.signingkey` in the clone, else the gpg key matching
   `user.name <user.email>`. Set `user.signingkey` to the key from the httpd
   `KEYS` file so the tag and the tarballs carry the same signature.
9. **`git describe` on `2.4.x`** never finds a release tag because the tag
   is one commit off the branch. Same shape as the mirror produces today, so
   no tooling change expected, but note it.
10. **`PROJECT` derivation.** In git mode it is the basename of
    `GIT_SRC_URL`. A fork not named `httpd` needs `PROJECT=httpd` or every
    tarball is misnamed. The scripts do not detect this.
11. **Shallow candidate clone.** `dist/${FULL_VERSION}-candidate` is a
    `--depth 1` clone. `buildconf`, the docs build and pushing work; anything
    that wants history inside the candidate checkout would not.
12. **Push access is checked with `git push --dry-run`** to a ref name that
    does not exist, which exercises the server's receive-pack and therefore
    credentials and permission. Whether GitHub applies branch protection
    rules at dry-run time is not guaranteed, so a protected `*-candidate`
    pattern (item 5) would still only show up at the real push in `r0`.
13. **Local pmc seed.** `DIST_MODE=local` exports `pmc/httpd` in full once
    per `dist/` lifetime. If CVE JSON files change in pmc during a
    multi-day rehearsal, `rm -rf dist/pmc dist/local-dist-mode-seed/pmc` before `r4` to
    re-seed; `r4` folds whatever the local copy says.
14. **`reset-candidate.sh` removes `dist/`**, including the seed, so after
    a reset the next `r0` re-exports dist and pmc. Fine, just slow.
15. **The vote email** names the real `dist.apache.org` dev URL even though
    nothing was uploaded. Correct text for a real run, misleading in a
    rehearsal; do not send it.
16. **`r6` CDN check is skipped** in local mode, so the `cmp` logic against
    downloads.apache.org and dlcdn is only exercised by a real release.

Things not covered by a fork rehearsal at all, and verified only by the
first real git release: real `svn commit` to dist and pmc through the
`DIST_MODE=svn` wrappers (identical code to today, verified by the svn
regression run below), CDN propagation, the website buildbot, gitbox
credential handling for `apache/httpd`.

## 6. svn regression run

The refactor moved the svn code into `scm-svn.sh` and the dist/pmc verbs into
`dist-lib.sh`. To prove the svn path is unchanged without a real release,
run from the real `2.4.x` svn checkout during a quiet period:

```
export DIST_MODE=local        # SCM=svn is detected from the working copy
$DEV_TOOLS/release/r0-make-candidate.sh rc9
$DEV_TOOLS/release/r1-make-tars.sh
$DEV_TOOLS/release/r2-prep-vote.sh
$DEV_TOOLS/release/reset-candidate.sh
```

The only ASF-visible effect is a short-lived
`tags/2.4.NN-rc9-candidate` in svn plus its "Post tag updates" commit, both
removed by the reset. `r3` to `r6` in svn mode are verified by the first
real release after the refactor; `DIST_MODE=local` has no effect on the
source repository, so the `svn mv` of the tag is not rehearsed.

## 7. What to report back

For each run note: the fork, the version used, the `dist/VERSION` contents,
the ref listing of the fork after step 6 and after step 8, the section 4
diff output, and anything that needed a manual fix. Findings that change
tarball content (section 5, items 1 to 3) block cutover; the rest are
documentation or decisions.
