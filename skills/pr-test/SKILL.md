---
name: pr-test
description: Evaluate a GitHub PR against apache/httpd and prove it with a pyhttpd test - judge the change, then build a red-to-green branch that fails before the PR commit and passes after it. Use for "evaluate PR 529", "review PR NNN", "test a PR", "prove PR NNN fixes the bug".
---

# Evaluate a PR and prove it with a test

Given a PR number, judge the change, then build a `prNNN-testing` branch whose history
is: a new pyhttpd test that fails, followed by the submitter's commit(s) applied
unchanged, after which it passes. The branch is the deliverable — it shows the PR does
what it claims rather than merely looking plausible.

Usage: `/pr-test 529`, or `/pr-test 529 owner/repo` to override the source repo.

## 0. Preflight

- If the checkout has an `AGENTS.md`, read it first and follow it. Local guidance there
  (paths, build setup, commit and PR conventions) takes precedence over the defaults in
  this skill.
- Find the apache/httpd remote, `$UP`: `upstream` when the checkout has both an `origin`
  and an `upstream` remote (the usual triangle: `origin` is the user's fork), else
  `origin`. Check that it really points at apache/httpd:
  ```
  if git remote | grep -qx upstream && git remote | grep -qx origin; then UP=upstream; else UP=origin; fi
  git remote get-url $UP | grep -q '[:/]apache/httpd\(\.git\)\?$' || echo "$UP is not apache/httpd"
  ```
  If it isn't, ask the user which remote is apache/httpd. Below, `$UP` is that remote.
- The PR repo defaults to **`apache/httpd`**; pass `--repo apache/httpd` to every `gh`
  command (with a fork remote present, a bare `gh` may resolve to the fork).
- Find the user's GitHub fork: their login, and the remote that pushes to
  `<login>/httpd`:
  ```
  FORK_OWNER=$(gh api user --jq .login)
  git remote -v | grep "[:/]$FORK_OWNER/httpd\(\.git\)\? (push)"
  ```
  The first column is `<fork-remote>`, used in step 5. If no remote matches, ask the user
  which remote is their fork; never fall back to `$UP`.
- Working tree must be clean. If it isn't, offer a worktree under `.claude/worktrees/prNNN`
  — the name must stay **≤ 7 characters**: the `test/modules/arch/linux` suite binds a
  unix socket under the worktree path, which has to fit the 108-byte `sockaddr_un` limit.
- The tree must be configured and built: `Makefile` exists and `build/config_vars.mk` sets
  `PYTEST3`.
- `git fetch $UP`, then base everything on `$UP/trunk`. Local `trunk` is stale; never
  branch off it, and never off another topic branch. If the PR targets `2.4.x`, base on
  `$UP/2.4.x`.

## 1. Evaluate the change

```
gh pr view NNN --repo apache/httpd --json title,body,author,state,url,commits,files
gh pr diff NNN --repo apache/httpd
```

Read the surrounding in-tree code for every hunk — do not judge from the diff alone.
Assess:

- Is the diagnosis right, and is the fix the right one for it?
- Is it minimal, or does it carry unrelated churn?
- MMN / API / ABI impact; whether it is backportable to 2.4.x.
- httpd conventions: existing `ap_*` / `apr_*` helpers used rather than new local
  equivalents; no `APLOGNO()` on `APLOG_DEBUG`/`APLOG_TRACE*`.

Report the evaluation to the user.

**Gate:** if the change does not look reasonable, **stop here.** Report the concerns.
Create no branch and write no test.

## 2. Branch and write the test

```
git switch -c prNNN-testing $UP/trunk
```

Pick the pyhttpd package from the files the PR touches:

| PR touches | test package |
| --- | --- |
| `modules/aaa/` | `test/modules/aaa` |
| `modules/http2/` | `test/modules/http2` |
| `modules/metadata/` | `test/modules/metadata` |
| `modules/proxy/` | `test/modules/proxy` |
| `modules/ssl/` | `test/modules/ssl` |
| `modules/md/` | `test/modules/md` |
| `modules/generators/mod_status.c` | `test/modules/status` |
| `server/*.c`, generic filters | `test/modules/core` |
| core API (`ap_*` in `modules/http/http_request.c`, `http_protocol.c`) | `test/modules/core` |
| HTTP/1 protocol framing, trailers, strictness | `test/modules/http1` |

A PR touching several areas gets a test in **each** affected package. Route by what the
change *is*, not which directory it sits in: a core function that happens to live under
`modules/http/` belongs in `test/modules/core`.

If no shipped module exercises the code path, add the hook to a test module rather than
inventing a config for it. `test/pyhttpd/mod_aptest/mod_aptest.c` is rebuilt by
`HttpdTestSetup._add_aptest()` and loaded by every suite, so a hook there must be inert
unless the test asks for it — gate it on a request header. `test/modules/http1/mod_h1test/`
is the per-suite equivalent. After touching `mod_aptest.c`, run a second suite to confirm
the change is inert.

If nothing fits, create a package with `__init__.py`, `conftest.py`, `env.py`, and
`htdocs/` if it needs files; copy `test/modules/core/` as the simplest template. Nothing
registers a package anywhere — no list in `Makefile.in` or `configure.in`, pytest just
collects `test/modules/**/test_*.py`. **`__init__.py` is mandatory**: every `conftest.py`
does `from .env import ...`. `test/README.pytest` documents the layout.

Follow the house pattern — `test/modules/core/test_006_merge_lang.py` is a compact
example:

```python
class TestSomething:

    @pytest.fixture(autouse=True, scope='class')
    def _class_scope(self, env):
        conf = HttpdConf(env, extras={
            f"test1.{env.http_tld}": """
            SomeDirective on
            """,
        })
        conf.add_vhost_test1()
        conf.install()
        assert env.apache_restart() == 0

    def test_core_007_01(self, env):
        r = env.curl_get(env.mkurl("http", "test1", "/doc.html"))
        assert r.response["status"] == 200
```

- Name methods `test_<suite>_<NNN>_<NN>`, taking the next free number in the package.
- Assert on `r.response["status"]`, `r.response["header"][...]` (keys lowercased),
  `r.response["body"]`.
- Declare the module under test in the package's `*TestSetup.add_modules()`, or
  `add_optional_modules()` when it is build-conditional — see `test/modules/metadata/env.py`
  for the optional-module plus `has_shared_module()` idiom. A module in `add_modules()`
  with no `.so` aborts setup with "Unable to find modules", so it must be built as a DSO.
- `test/conftest.py` calls `env.check_error_log()` after every test and fails on any
  unignored error or warning. For log output the test expects, assert it with
  `env.httpd_error_log.scan_recent(re.compile(...))` and then clear it with
  `env.httpd_error_log.ignore_recent(lognos=["AHNNNNN"])`, as
  `test/modules/metadata/test_001_mime_magic.py` does.
- `test/modules/status` is gated behind `TEST_STATUS` in its `conftest.py`
  (`collect_ignore_glob`), so a status test needs that set in the environment.

The test must fail **for the reason the PR describes**. A failure from a config mistake
proves nothing — check the error log and the response to confirm the mechanism matches.

## 3. Show the test fails

Build from the **top level**:

```
make -j$(nproc)
```

`make -C modules/<dir>` does not relink the shared module, and `check/modules/*.so` are
symlinks to those `.libs` files, so a partial build silently tests old code. Check the
`.so` timestamp before trusting a result.

```
make check-pytest PYTEST_DIRS=test/modules/<pkg>
```

**The path must start with `test/`.** pytest's rootdir is the httpd top directory, so
`PYTEST_DIRS=modules/aaa` collects 0 items and exits 5 rather than erroring usefully. No
`make install` is needed — `check-pytest` builds a `check/` prefix and symlinks the built
modules into `check/modules/`.

If a run is interrupted, the `check/bin/httpd` it started survives and keeps ports
5001-5004 and 5100 bound, so every later run errors at setup rather than failing cleanly —
the tell is dozens of ERRORs and a runtime of minutes where a clean run takes seconds.
`apachectl -k stop` will not help once the pid file is gone, so kill it directly and
confirm the ports are free before re-running:

```
pgrep -af "$PWD/check/bin/httpd"
ss -ltn | grep -E ':500[1-4]|:5100'
```

Run the whole package, not just the new test, to establish a clean baseline. To narrow
down afterwards, call the same pytest the target uses (the *system* `pytest-3`, not the
`uv` venv):

```
PYHTTPD_CONFIG=$PWD/check/config.ini pytest-3 test/modules/<pkg> -k <name>
```

Capture the failure output verbatim for the report, then commit the test alone. A
brand-new test file's message is just:

```
* test/modules/<pkg>/test_NNN_foo.py: New test suite.

Co-Authored-By: <model> <noreply@anthropic.com>
GitHub: PR #NNN
```

A case added to an existing file gets the normal one-clause ChangeLog form. Never a
`Claude-Session` trailer.

## 4. Apply the PR commit AS-IS and show it passes

`$UP` has no PR refspec, so fetch the head explicitly:

```
git fetch $UP refs/pull/NNN/head:refs/remotes/$UP/pr/NNN
git cherry-pick -x <sha>...
```

Cherry-pick every commit in PR order. **AS-IS**: no rewording, no style fixes, no
squashing, no amending. Original authorship is preserved and the branch shows exactly what
the submitter proposed. If a commit does not apply cleanly to current trunk, stop and
report — editing the patch defeats the point.

Rebuild top-level `make -j$(nproc)` and re-run the same `check-pytest` command. The new
test must now pass **and** nothing else in the package may regress. Capture the output
verbatim.

If the test still fails, that is the headline result. Report it. Do not massage the test
until it goes green.

## 5. Push to the fork

Push to the user's fork (`<fork-remote>` from step 0):

```
git push <fork-remote> prNNN-testing:prNNN-testing
```

**Use the explicit refspec.** The branch tracks `$UP/trunk`, so with `push.default`
set to `upstream` (or `tracking`) a bare `git push <fork-remote> prNNN-testing` resolves
to `trunk` on the fork.

**Never push to `$UP`** (apache/httpd). Report the branch URL.

Do not open a PR: its subject and body must be shown to the user and approved first.
Offer to draft one.

## Notes

- Keep a running record at `.claude/sessions/prNNN-testing-session.md` in the main
  checkout (not a worktree, which gets removed), appended as work
  happens rather than written up at the end. Leave it untracked.
- Stay inside this checkout: no `$HOME`, no sibling trees, no scratch directories.
- Add no `changes-entries/` file. That belongs to the PR author; this branch is their
  commit plus a test.
