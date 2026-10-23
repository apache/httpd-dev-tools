#!/usr/bin/env bash

# Commit staged release changes to the dist and pmc SVN repositories,
# the source repository (svn or git) and the project website

#Useful for debugging
#set -x

#Bail when non-zero return codes are encountered
set -e

usage () {
    cat <<EOF 1>&2
usage: $0 [options] [version]
  Commit staged release changes to project distribution, source repositories
  and web site.
  Arguments:
    version        as 'm.n.p(-suffix)?', the version to use.
  Options:
    -h             print usage information
    -u user-id     your apache user-id, e.g 'ylavic'
EOF
  exit 1
}

asf_id="$USER"

while getopts "hu:" opt; do
    case $opt in
        h)  usage
            ;;
        u)  asf_id="$OPTARG"
            ;;
    esac
done
shift $((OPTIND-1))

source `dirname $0`/common-lib.sh
source `dirname $0`/env.sh

detect_checkout
detect_version $1

AO_DIST_PATH="${DIST_DIR}/apache.org-dist"
AO_DIST_RELEASE_PATH="${AO_DIST_PATH}/release/${PROJECT}"

DIST_SITEPATH="${DIST_DIR}/site"

echo "updating local checkout"
scm_update_checkout

test -d "${AO_DIST_RELEASE_PATH}" ||
  fail "staged changes for dist.apache.org not found in ${AO_DIST_RELEASE_PATH}"
test -d "${DIST_DIR}/pmc" ||
  fail "staged changes for pmc repository not found in ${DIST_DIR}/pmc"
test -d "${DIST_SITEPATH}" ||
  fail "staged changes for project site not found in ${DIST_SITEPATH}"

echo
echo "PENDING REPOSITORY CHANGES"
echo "--------"
echo "changes staged for ${SVN_DIST_URL} (DIST_MODE=${DIST_MODE})"
dist_stat "${AO_DIST_PATH}"
echo "--------"
echo "changes staged in pmc/${PROJECT} (DIST_MODE=${DIST_MODE})"
pmc_stat "${DIST_DIR}/pmc"
echo "--------"
echo "git changes staged in ${DIST_SITEPATH}"
(cd "${DIST_SITEPATH}" && git status)
echo "--------"
echo "${SCM} changes staged in local checkout for ${SRC_URL}"
scm_status .

if dist_mode_is_local; then
  cat <<EOF
DIST_MODE=local: of the changes above,
  - dist.apache.org and pmc stay local (nothing is committed there)
  - the site commit is made in ${DIST_SITEPATH} but not pushed
  - the source checkout commit IS pushed to ${SRC_URL}
EOF
fi
note=`local_mode_note " (DIST_MODE=local: only the source commit leaves this machine)"`
if ask_yes_no "Do you want to commit these changes?${note}"; then
  if dist_mode_is_local; then
    echo "WARNING: the source commit to ${SRC_URL} is irreversible; the rest stays local."
  else
    echo "WARNING: this is quite irreversible!"
  fi
  if ask_yes_no "Do you REALLY want to commit these changes?${note}"; then
    MSG="publishing release ${PROJECT}-${VERSION}"

    pmc_commit "${MSG}" "${DIST_DIR}/pmc"
    # dev is included: r4 moved the CHANGES files from dev to release
    dist_commit "${MSG}" "${AO_DIST_PATH}"
    # the source checkout: svn commit, or git commit + push to GIT_SRC_URL
    scm_commit_checkout "${MSG}"
    if dist_mode_is_local; then
      (cd "${DIST_SITEPATH}" && git commit -m "${MSG}")
      echo "DIST_MODE=local: not pushing ${DIST_SITEPATH} to ${GIT_SITE_URL}"
    else
      (cd "${DIST_SITEPATH}" && git commit -m "${MSG}" && git push)
    fi

    # success exit
    save_version
    exit 0
  fi
fi
# failure exit
exit 1
