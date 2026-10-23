#!/usr/bin/env bash

# Undo a rehearsal on a personal fork: remove the release tag and every
# candidate branch of a version, put the release branch back to upstream,
# reset the local clone and remove dist/.
#
# USAGE: reset-fork.sh [options] version
# EXAMPLE: reset-fork.sh 2.4.70
#
# Refuses to run unless the source repository (the clone's origin, see
# env.sh) is a fork, i.e. not GIT_UPSTREAM_REPO. Deleting tags and force
# pushing branches is exactly what the release scripts never do on the
# real repository; here it is the point.

#Bail when non-zero return codes are encountered
set -e

usage () {
    cat <<EOF 1>&2
usage: $0 [options] version
  remove all traces of a rehearsed release from a personal fork:
    - the release tag 'version' and every 'version-*-candidate' branch
    - commits the rehearsal pushed to the release branch (reset to upstream)
    - local changes in this clone, and the dist/ directory
  Arguments:
    version        as 'm.n.p', without suffix, e.g. 2.4.70
  Options:
    -h             print usage information
    -y             never ask, always assume yes
    -k             keep the local clone and dist/ (only clean the fork)
EOF
  exit 1
}

KEEP_LOCAL=""
while getopts "hyk" opt; do
    case $opt in
        h)  usage
            ;;
        y)  ALWAYS_YES=1
            ;;
        k)  KEEP_LOCAL=1
            ;;
    esac
done
shift $((OPTIND-1))

source `dirname $0`/common-lib.sh
source `dirname $0`/env.sh

VERSION="$1"
test -n "${VERSION}" || usage
case "${VERSION}" in
  *.*.*-*) fail "give the version without suffix (2.4.70, not ${VERSION})" ;;
  *.*.*) ;;
  *) usage ;;
esac

test "${SCM}" = git || fail "this only applies to a git clone of a fork (SCM=${SCM})"
git_src_is_fork || fail "${GIT_SRC_URL} is not a fork (GIT_UPSTREAM_REPO=${GIT_UPSTREAM_REPO}); refusing"

# upstream to reset the branch to
GIT_UPSTREAM_URL="${GIT_UPSTREAM_URL:-https://github.com/${GIT_UPSTREAM_REPO}.git}"

scm_validate
SRC_URL="${GIT_SRC_URL}"
SRC_BRANCH=`git symbolic-ref --short HEAD 2>/dev/null` || fail "HEAD is detached; check out the release branch"
assure_release_branch

echo "fork:     ${GIT_SRC_URL}"
echo "upstream: ${GIT_UPSTREAM_URL}"
echo "branch:   ${SRC_BRANCH}"
echo

# ---- what the fork has for this version --------------------------------------
refs=`git ls-remote "${GIT_SRC_URL}" "refs/tags/${VERSION}" "refs/heads/${VERSION}-*candidate" "refs/heads/${VERSION}-candidate" | awk '{print $2}' | grep -v '\^{}$' | sort -u || true`
fork_tip=`git ls-remote "${GIT_SRC_URL}" "refs/heads/${SRC_BRANCH}" | cut -f1`
test -n "${fork_tip}" || fail "no branch ${SRC_BRANCH} on ${GIT_SRC_URL}"
echo "fetching ${SRC_BRANCH} from ${GIT_UPSTREAM_URL} to learn its current tip ..."
git fetch -q "${GIT_UPSTREAM_URL}" "refs/heads/${SRC_BRANCH}" || fail "unable to fetch ${SRC_BRANCH} from ${GIT_UPSTREAM_URL}"
upstream_tip=`git rev-parse FETCH_HEAD`
git fetch -q "${GIT_SRC_URL}" "refs/heads/${SRC_BRANCH}"

echo "refs for ${VERSION} on the fork:"
if test -n "${refs}"; then
  echo "${refs}" | sed -e 's/^/  /'
else
  echo "  none"
fi
echo "branch ${SRC_BRANCH}: fork ${fork_tip}, ${GIT_UPSTREAM_REPO} ${upstream_tip}"
branch_state=same
if test "${fork_tip}" != "${upstream_tip}"; then
  if git merge-base --is-ancestor "${upstream_tip}" "${fork_tip}"; then
    branch_state=ahead
    echo "  commits on the fork's ${SRC_BRANCH} that ${GIT_UPSTREAM_REPO} does not have (the rehearsal's):"
    git log --oneline "${upstream_tip}..${fork_tip}" | sed -e 's/^/    /'
  elif git merge-base --is-ancestor "${fork_tip}" "${upstream_tip}"; then
    branch_state=behind
    n=`git rev-list --count "${fork_tip}..${upstream_tip}"`
    echo "  the fork's ${SRC_BRANCH} is ${n} commits behind ${GIT_UPSTREAM_REPO}; nothing of the rehearsal is on it"
  else
    branch_state=diverged
    warn "the fork's ${SRC_BRANCH} and ${GIT_UPSTREAM_REPO} have diverged; resetting discards these fork commits:"
    git log --oneline "${upstream_tip}..${fork_tip}" | sed -e 's/^/    /'
  fi
fi
echo

# ---- fork: tags and candidate branches ---------------------------------------
if test -n "${refs}"; then
  if ask_yes_no "Delete these refs on ${GIT_SRC_URL}?"; then
    for r in ${refs}; do
      echo "deleting ${r}"
      git push -q "${GIT_SRC_URL}" --delete "${r}"
    done
  fi
fi

# ---- fork: branch back to upstream -------------------------------------------
# GIT_UPSTREAM_URL is only read, to learn where the branch was before the
# rehearsal; the push goes to the fork.
if test "${branch_state}" != same; then
  if ask_yes_no "Force push ${SRC_BRANCH} on ${GIT_SRC_URL} to ${upstream_tip}, the current tip of ${GIT_UPSTREAM_REPO}?"; then
    git push -q --force "${GIT_SRC_URL}" "${upstream_tip}:refs/heads/${SRC_BRANCH}"
    echo "fork ${SRC_BRANCH} reset to ${upstream_tip}"
  fi
fi

# ---- local clone --------------------------------------------------------------
if git show-ref -q --tags "${VERSION}"; then
  echo "deleting local tag ${VERSION}"
  git tag -d "${VERSION}" >/dev/null
fi
if test -z "${KEEP_LOCAL}"; then
  dirty=`git status --porcelain -- . ":(exclude)${DIST_DIR}"`
  head=`git rev-parse HEAD`
  if test -n "${dirty}" -o "${head}" != "${upstream_tip}"; then
    ndirty=`echo "${dirty}" | grep -c . || true`
    echo "local clone: HEAD ${head}, ${ndirty} modified/untracked files"
    if ask_yes_no "Discard local changes and reset the local ${SRC_BRANCH} to ${upstream_tip}?"; then
      git checkout -q -- .
      git clean -qfd -e "${DIST_DIR}"
      git reset -q --hard "${upstream_tip}"
      echo "local ${SRC_BRANCH} reset to ${upstream_tip}"
    fi
  fi
  if test -d "${DIST_DIR}"; then
    if ask_yes_no "Remove ${DIST_DIR}/ (candidate clone, tarballs, local dist/pmc copies, site clone)?"; then
      rm -rf "${DIST_DIR}"
    fi
  fi
fi

echo
echo "fork now has:"
git ls-remote "${GIT_SRC_URL}" | grep -E "refs/(heads|tags)/" | sed -e 's/^/  /'
echo "Ok: rehearsal of ${VERSION} removed from ${GIT_SRC_URL}."
