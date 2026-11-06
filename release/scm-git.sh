# git backend for the httpd source repository.
#
# Sourced by common-lib.sh; called through the scm_* dispatchers there.
#
# Model (see GIT-MIGRATION-PLAN.md, section 4.3):
#  - the candidate is a branch refs/heads/${CANDIDATE_TAG}, created on the
#    server from the exact commit of the local checkout, and advanced by the
#    "Post tag updates" commit. It is deleted when voted down or released.
#  - the release is an annotated (optionally signed) tag refs/tags/${RELEASE_TAG}
#    pointing at the candidate's final commit. Tags are never deleted or moved.
#  - every remote operation names GIT_SRC_URL explicitly. env.sh takes that
#    URL from the remote GIT_SRC_REMOTE of the working directory ('upstream'
#    when the clone has such a remote, else 'origin') unless GIT_SRC_URL is
#    given; the remote name itself is never used afterwards.

# git_host_from_url URL   prints the host part of a git URL, empty for
# local paths and file:// URLs
git_host_from_url() {
  case "$1" in
    *://*)
      h="${1#*://}"      # user@host:port/path or host/path
      h="${h%%/*}"
      h="${h##*@}"
      h="${h%%:*}"
      ;;
    /*|./*|../*) h="" ;;
    *@*:*)               # scp style: user@host:path
      h="${1#*@}"
      h="${h%%:*}"
      ;;
    *:*)                 # scp style without user: host:path
      h="${1%%:*}"
      ;;
    *) h="" ;;
  esac
  echo "$h"
}

# github_repo_from_url URL   prints '<owner>/<repo>' for github.com URLs
github_repo_from_url() {
  case "$1" in
    git@github.com:*)        r="${1#git@github.com:}" ;;
    ssh://git@github.com/*)  r="${1#ssh://git@github.com/}" ;;
    https://github.com/*)    r="${1#https://github.com/}" ;;
    *) return 0 ;;
  esac
  r="${r%/}"
  r="${r%.git}"
  echo "$r"
}

# true when GIT_SRC_URL is not the canonical repository (GIT_UPSTREAM_REPO on
# github.com, or the same repository on gitbox.apache.org)
git_src_is_fork() {
  case "${GIT_SRC_URL}" in
    https://gitbox.apache.org/repos/asf/*|git@gitbox.apache.org:*|ssh://git@gitbox.apache.org/*)
      return 1 ;;
  esac
  test "`github_repo_from_url "${GIT_SRC_URL}"`" != "${GIT_UPSTREAM_REPO}"
}

scm_git_assure_commands() {
  type git >/dev/null 2>&1 || fail "needed command not found: git"
  # early credential check, convenience only
  case "${GIT_SRC_URL}" in
    https://github.com/*)
      if type gh >/dev/null 2>&1; then
        gh auth status >/dev/null 2>&1 ||
          warn "'gh auth status' failed; pushes to ${GIT_SRC_URL} may ask for credentials (gh auth login && gh auth setup-git)"
      fi
      ;;
  esac
}

scm_git_validate() {
  test "`git rev-parse --is-inside-work-tree 2>/dev/null`" = "true" ||
    fail "SCM=git but the local directory is not a git work tree"
  top=`git rev-parse --show-toplevel`
  test "$top" = "`pwd -P`" ||
    fail "please run from the top of the git work tree: $top"
}

# Inspect the local clone and populate
# SRC_URL        GIT_SRC_URL
# SRC_BRANCH     e.g. 'trunk' or '2.4.x'
# SRC_REV        full sha of HEAD
# SRC_REV_SHORT  abbreviated sha, for messages
# PROJECT        basename of GIT_SRC_URL unless set in the environment
# HEAD must already be on the remote branch: a candidate is created from
# SRC_REV server side, so unpushed local commits must not exist.
scm_git_detect_checkout() {
  test -n "${GIT_SRC_URL}" ||
    fail "GIT_SRC_URL is empty: this clone has no remote named '${GIT_SRC_REMOTE}' (git remote -v). Add it, set GIT_SRC_REMOTE to the remote to use, or set GIT_SRC_URL."
  echo "source repository: ${GIT_SRC_URL} (${GIT_SRC_URL_ORIGIN})"
  SRC_URL="${GIT_SRC_URL}"
  SRC_BRANCH=`git symbolic-ref --short HEAD 2>/dev/null` ||
    fail "HEAD is detached; check out the branch to release from"
  SRC_REV=`git rev-parse HEAD` || fail "unable to determine HEAD commit"
  SRC_REV_SHORT=`git rev-parse --short HEAD`
  if test -z "$PROJECT"; then
    PROJECT=`basename "${GIT_SRC_URL}"`
    PROJECT="${PROJECT%.git}"
  fi
  echo "fetching ${SRC_BRANCH} from ${GIT_SRC_URL} ..."
  git fetch -q "${GIT_SRC_URL}" "refs/heads/${SRC_BRANCH}" ||
    fail "unable to fetch branch ${SRC_BRANCH} from ${GIT_SRC_URL}"
  git merge-base --is-ancestor HEAD FETCH_HEAD ||
    fail "local ${SRC_BRANCH} (${SRC_REV_SHORT}) has commits that are not on ${GIT_SRC_URL}; push them first"
  scm_git_assure_identity
  scm_git_assure_push_access
}

# the commits made by the scripts must be attributed to the RM
scm_git_assure_identity() {
  # 'git config' exits 1 when a key is unset; do not let set -e act on that
  GIT_USER_NAME=`git config user.name || true`
  GIT_USER_EMAIL=`git config user.email || true`
  test -n "${GIT_USER_NAME}" -a -n "${GIT_USER_EMAIL}" ||
    fail "git user.name/user.email are not set for this clone (git config user.email you@apache.org); the release commits must be attributed to you"
}

# a dry-run push contacts the server's receive-pack, which checks the
# credentials and push permission without changing anything. The ref name
# does not exist and is never created.
scm_git_assure_push_access() {
  if ! out=`git push --dry-run "${GIT_SRC_URL}" "HEAD:refs/heads/release-tools-push-check" 2>&1`; then
    case "${GIT_SRC_URL}" in
      https://github.com/*)
        hint="For https URLs run 'gh auth login' then 'gh auth setup-git', or use an ssh URL with your key." ;;
      *github.com*)
        hint="Check your ssh key, and that your GitHub account is linked at https://gitbox.apache.org/boxer/ for apache repositories." ;;
      *)
        hint="" ;;
    esac
    fail "cannot push to ${GIT_SRC_URL}:
${out}
${hint}"
  fi
}

# /dist is not in httpd's .gitignore; ignore it here like svn:ignore does
scm_git_assure_clean_checkout() {
  out=`git status --porcelain -- . ":(exclude)${DIST_DIR}"`
  test -z "$out" || fail "local checkout is not clean:
$out
Untracked files ('??'): preview with 'git clean -fdn', remove with 'git clean -fd'.
Modified files: 'git stash' to keep them, 'git checkout -- <file>' to drop them."
}

# When GIT_SIGN_TAGS=1, make sure 'git tag -s' works here before anything
# is pushed: create a throwaway signed tag on HEAD with the same config r3
# will use, then delete it. This may prompt for the key's passphrase.
scm_git_assure_signing_key() {
  test "${GIT_SIGN_TAGS}" = 1 || return 0
  key=`git config user.signingkey || true`
  fmt=`git config gpg.format || true`
  echo "checking that release tags can be signed (${fmt:-openpgp} key ${key:-matching "${GIT_USER_NAME} <${GIT_USER_EMAIL}>"}) ..."
  probe="release-tools-sign-check-$$"
  if ! out=`git tag -s -m "signing check" "$probe" HEAD 2>&1`; then
    hint=""
    case "${out}" in
      *"Inappropriate ioctl"*|*"No such device"*)
        hint="gpg could not open a terminal for the passphrase prompt (GPG_TTY=${GPG_TTY:-unset}). Run from a terminal, or 'export GPG_TTY=\$(tty)' in the shell.
" ;;
    esac
    fail "cannot sign tags:
${out}
${hint}Set the key from the httpd KEYS file with 'git config user.signingkey <keyid>' in this clone, make sure gpg can use it (gpg --list-secret-keys), or set GIT_SIGN_TAGS=0 for unsigned release tags."
  fi
  git tag -d "$probe" >/dev/null
}

# scm_git_refspec NAME KIND   full ref name for a candidate (branch) or release (tag)
scm_git_refspec() {
  case "$2" in
    candidate) echo "refs/heads/$1" ;;
    release)   echo "refs/tags/$1" ;;
    *) fail "unknown ref kind: $2" ;;
  esac
}

# scm_git_ref_exists NAME KIND
scm_git_ref_exists() {
  git ls-remote --exit-code "${GIT_SRC_URL}" "`scm_git_refspec "$1" "$2"`" >/dev/null 2>&1
}

# sha of the candidate branch on the server, empty if it does not exist
scm_git_candidate_sha() {
  git ls-remote "${GIT_SRC_URL}" "refs/heads/${CANDIDATE_TAG}" 2>/dev/null | cut -f1
}

scm_git_candidate_ref() {
  echo "branch ${CANDIDATE_TAG} on ${GIT_SRC_URL}"
}

scm_git_describe_candidate() {
  sha=`scm_git_candidate_sha`
  echo "branch ${CANDIDATE_TAG} @ ${sha:-(not on server)}"
}

# create the candidate branch on the server from the exact local commit
scm_git_create_candidate() {
  echo "pushing ${SRC_BRANCH}@${SRC_REV_SHORT} as branch ${CANDIDATE_TAG} to ${GIT_SRC_URL}"
  git push "${GIT_SRC_URL}" "${SRC_REV}:refs/heads/${CANDIDATE_TAG}"
  echo "branch ${CANDIDATE_TAG} is now on ${GIT_SRC_URL}"
}

# scm_git_checkout_candidate DIR   an independent clone, 'origin' is GIT_SRC_URL.
# The identity of the main clone is copied in, so a user.email set only
# locally there still applies to the "Post tag updates" commit.
scm_git_checkout_candidate() {
  echo "cloning branch ${CANDIDATE_TAG} from ${GIT_SRC_URL} into $1"
  git clone -q --branch "${CANDIDATE_TAG}" --single-branch --depth 1 "${GIT_SRC_URL}" "$1"
  git -C "$1" config user.name "${GIT_USER_NAME}"
  git -C "$1" config user.email "${GIT_USER_EMAIL}"
}

# scm_git_update_candidate DIR
scm_git_update_candidate() {
  git -C "$1" pull --ff-only
}

# scm_git_status DIR
scm_git_status() {
  git -C "$1" status --short
}

# scm_git_commit_candidate DIR MSG   commit versioned files only (like svn) and push
scm_git_commit_candidate() {
  email=`git -C "$1" config user.email || true`
  test -n "$email" || fail "git user.email is not set in $1; set it so the commit is attributed to you"
  # like 'svn commit', committing nothing is not an error (rerun of r0)
  if test -n "`git -C "$1" status --porcelain --untracked-files=no`"; then
    git -C "$1" commit -q -a -m "$2"
  else
    echo "nothing to commit in $1"
  fi
  # 'origin' of this clone is GIT_SRC_URL (see scm_git_checkout_candidate),
  # never the 'origin' of the release manager's own checkout.
  echo "pushing branch ${CANDIDATE_TAG} to ${GIT_SRC_URL}"
  git -C "$1" push origin HEAD
  echo "pushed `git -C "$1" rev-parse --short HEAD` to branch ${CANDIDATE_TAG} on ${GIT_SRC_URL}"
}

# how to follow the CI run triggered by the candidate push
scm_git_ci_hint() {
  if test -n "${GH_REPO}" && type gh >/dev/null 2>&1; then
    cat <<EOT
CI for the candidate branch:
  gh run list -R ${GH_REPO} --branch ${CANDIDATE_TAG}
  gh run watch -R ${GH_REPO}
EOT
  elif test -n "${GIT_WEB_URL}"; then
    echo "CI for the candidate branch: ${GIT_WEB_URL}/actions"
  fi
}

# scm_git_export NAME DEST   pristine tree of candidate branch NAME into DEST,
# taken from the server, not from the local clone
scm_git_export() {
  git fetch -q "${GIT_SRC_URL}" "refs/heads/$1" ||
    fail "unable to fetch candidate branch $1 from ${GIT_SRC_URL}"
  mkdir -p "$2"
  # pax_global_header written by git archive is dropped by tar -x
  git archive --format=tar FETCH_HEAD | tar -x -C "$2"
}

# scm_git_promote_candidate MSG   tag the candidate's final commit as the
# release and retire the candidate branch. Never overwrites a tag.
scm_git_promote_candidate() {
  if scm_git_ref_exists "${RELEASE_TAG}" release; then
    fail "release tag ${RELEASE_TAG} already exists on ${GIT_SRC_URL}"
  fi
  git fetch -q "${GIT_SRC_URL}" "refs/heads/${CANDIDATE_TAG}" ||
    fail "unable to fetch candidate branch ${CANDIDATE_TAG} from ${GIT_SRC_URL}"
  sign=""
  if test "${GIT_SIGN_TAGS}" = 1; then
    sign="-s"
  fi
  git tag -a $sign "${RELEASE_TAG}" -m "$1" FETCH_HEAD
  git push "${GIT_SRC_URL}" "refs/tags/${RELEASE_TAG}"
  git push "${GIT_SRC_URL}" --delete "refs/heads/${CANDIDATE_TAG}"
}

# scm_git_delete_candidate MSG
scm_git_delete_candidate() {
  git push "${GIT_SRC_URL}" --delete "refs/heads/${CANDIDATE_TAG}"
}

# fast-forward the local branch; local edits are stashed around the pull
scm_git_update_checkout() {
  git pull --ff-only --autostash "${GIT_SRC_URL}" "refs/heads/${SRC_BRANCH}" ||
    fail "unable to fast-forward ${SRC_BRANCH} from ${GIT_SRC_URL}. Resolve this by hand (git status, git stash, git pull --ff-only ${GIT_SRC_URL} ${SRC_BRANCH}, git stash pop) and rerun."
}

# scm_git_commit_checkout MSG   commit versioned files only (like svn) and push
scm_git_commit_checkout() {
  if test -n "`git status --porcelain --untracked-files=no`"; then
    git commit -a -m "$1"
  else
    echo "nothing to commit in the local checkout"
  fi
  git push "${GIT_SRC_URL}" "HEAD:refs/heads/${SRC_BRANCH}"
}

# text for the vote email: a branch can move, so include the sha
scm_git_candidate_source_text() {
  sha=`scm_git_candidate_sha`
  if test -n "${GIT_WEB_URL}"; then
    cat <<EOT
The candidate source is found at <${GIT_WEB_URL}/tree/${CANDIDATE_TAG}>
(branch ${CANDIDATE_TAG}, commit ${sha}).
EOT
  else
    cat <<EOT
The candidate source is branch ${CANDIDATE_TAG} of ${GIT_SRC_URL}
(commit ${sha}).
EOT
  fi
}
