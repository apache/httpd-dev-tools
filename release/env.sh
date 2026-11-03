# Defaults for the release scripts. Every variable can be overridden from the
# environment, e.g. SCM=git GIT_SRC_URL=git@github.com:me/httpd.git r0-make-candidate.sh
#
# common-lib.sh is sourced before this file, so its helpers are available.

DIST_DIR="${DIST_DIR:-dist}"

# Branches a release may be cut from, space separated, by their short name
# ('2.4.x' matches svn branches/2.4.x and git 2.4.x). Add 'trunk' here to
# allow releases from trunk again.
RELEASE_BRANCHES="${RELEASE_BRANCHES:-2.4.x}"

# svn repositories that stay svn regardless of SCM below
SVN_DIST_URL="${SVN_DIST_URL:-https://dist.apache.org/repos/dist/}"
SVN_PMC_URL="${SVN_PMC_URL:-https://svn.apache.org/repos/private/pmc}"
SVN_DOCS_BUILD_URL="${SVN_DOCS_BUILD_URL:-https://svn.apache.org/repos/asf/httpd/docs-build}"

# project web site (git); point at a fork for rehearsals
GIT_SITE_URL="${GIT_SITE_URL:-git@github.com:apache/httpd-site.git}"

# Backend for the httpd *source* repository: 'svn' or 'git'. Detected from
# the checkout the scripts run in (.svn or .git at the top). Setting SCM
# explicitly is possible but it is validated against the checkout anyway.
# Detection failures are reported by detect_checkout, so scripts that do
# not need a checkout (cve-change.sh) keep working from any directory.
if test -z "${SCM}"; then
  SCM=$(scm_detect_type || true)
fi

# git backend: the repository every remote operation uses (fetch, ls-remote,
# push, clone). Taken from the URL of a remote of the working directory;
# the scripts then pass that URL explicitly and never use the remote name.
#
# The project releases from github.com:apache/httpd. The usual clone layout
# is origin = your fork, upstream = apache/httpd, so the remote named
# 'upstream' is used when the clone has one and 'origin' otherwise (a
# direct clone of apache/httpd). A clone whose chosen remote is a fork
# makes every run a rehearsal (DIST_MODE=local is implied for forks); set
# GIT_SRC_REMOTE=origin explicitly to rehearse from a clone that also has
# an 'upstream' remote.
if test -z "${GIT_SRC_REMOTE}" -a "${SCM}" = git; then
  if git remote get-url upstream >/dev/null 2>&1; then
    GIT_SRC_REMOTE=upstream
  else
    GIT_SRC_REMOTE=origin
  fi
fi
GIT_SRC_REMOTE="${GIT_SRC_REMOTE:-upstream}"

if test -z "${GIT_SRC_URL}" -a "${SCM}" = git; then
  GIT_SRC_URL=$(git remote get-url "${GIT_SRC_REMOTE}" 2>/dev/null || true)
  GIT_SRC_URL_ORIGIN="remote ${GIT_SRC_REMOTE}"
else
  GIT_SRC_URL_ORIGIN="environment"
fi

# Derived for github.com hosted repositories: '<owner>/<repo>' for 'gh -R'
# and the browsable base URL for vote emails and CI hints. Empty otherwise.
if test -z "${GH_REPO}"; then
  GH_REPO=`github_repo_from_url "${GIT_SRC_URL}"`
fi
if test -z "${GIT_WEB_URL}" -a -n "${GH_REPO}"; then
  GIT_WEB_URL="https://github.com/${GH_REPO}"
fi

# The host of GIT_SRC_URL, exported for 'gh' (which uses GH_HOST to pick the
# GitHub host it talks to). Deliberately overrides a GH_HOST already in the
# environment, e.g. one pointing at a corporate GitHub, so that gh follows
# the source repository. Left alone only when the URL has no host (file://
# and local paths).
gh_host=`git_host_from_url "${GIT_SRC_URL}"`
if test -n "${gh_host}"; then
  GH_HOST="${gh_host}"
  export GH_HOST
fi
unset gh_host

# git backend: create the release tag with 'git tag -s' (1) or unsigned (0).
# The key is whatever git uses for -s: user.signingkey in the clone, else a
# gpg key matching user.name <user.email>. r0 and r3 check early that this
# works. Set user.signingkey to the key from the httpd KEYS file.
GIT_SIGN_TAGS="${GIT_SIGN_TAGS:-1}"

# gpg learns the terminal for its passphrase prompt from GPG_TTY. When git
# signs a tag it pipes the data to gpg, so gpg cannot find the terminal on
# its own ("signing failed: Inappropriate ioctl for device"). Set it when
# the scripts run on a terminal and the shell did not already export it.
if test -z "${GPG_TTY}" && gpg_tty=`tty 2>/dev/null`; then
  export GPG_TTY="${gpg_tty}"
fi
unset gpg_tty

# Project name, used for tarball and directory names. Derived from the
# checkout (svn) or GIT_SRC_URL (git) when empty; set it when rehearsing
# against a fork that is not named 'httpd'.
PROJECT="${PROJECT:-}"

# The canonical source repository in git mode. Anything else in GIT_SRC_URL
# is treated as a personal fork, i.e. a rehearsal.
GIT_UPSTREAM_REPO="${GIT_UPSTREAM_REPO:-apache/httpd}"

# 'svn': dist.apache.org and pmc are real svn checkouts and get committed.
# 'local': they are plain directories seeded once from a read-only export and
#          never committed. For rehearsals against a fork, see README.md.
# Implied: 'local' when SCM=git and GIT_SRC_URL is a fork. An explicit
# DIST_MODE=svn on a fork is refused unless FORCE_DIST_SVN=1.
DIST_MODE_ORIGIN="explicit"
if test -z "${DIST_MODE}"; then
  if test "${SCM}" = git && git_src_is_fork; then
    DIST_MODE=local
    DIST_MODE_ORIGIN="implied by fork ${GIT_SRC_URL}"
  else
    DIST_MODE=svn
    DIST_MODE_ORIGIN="default"
  fi
fi
