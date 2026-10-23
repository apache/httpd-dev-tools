#!/usr/bin/env bash

# Reset a candidate that is cancelled/voted down
#
# USAGE: reset-candidate.sh [version]
# version: x.y.z (example 2.4.38)

#Useful for debugging
#set -x

#Bail when non-zero return codes are encountered
set -e


usage () {
    cat <<EOF 1>&2
usage: $0 [options] [version]
  reset a candidate that is cancelled. Remove all appearances in
  the repositories.
  If no version is given, the current version in the checkout is used.
  Arguments:
    version        as 'm.n.p(-suffix)?', the version to use.
  Options:
    -h             print usage information
    -y             never ask, always assume yes
EOF
  exit 1
}

while getopts "hy" opt; do
    case $opt in
        h)  usage
            ;;
        y)  ALWAYS_YES=1
            ;;
    esac
done
shift $((OPTIND-1))

source `dirname $0`/common-lib.sh
source `dirname $0`/env.sh

detect_checkout
detect_version $1

echo "You are about to remove any intermediary files for ${PROJECT}-${FULL_VERSION}"
if ! ask_yes_no "Is this what you want?"; then
  exit 1
fi

if scm_ref_exists "$RELEASE_TAG" release; then
  fail "release already tagged as ${RELEASE_TAG} in ${SRC_URL}"
else
  echo "OK: $VERSION has not been tagged as release yet."
fi

# the prefixes that tarballs would have
VOTE_FILE="${PROJECT}-${FULL_VERSION}"
RELEASE_FILE="${PROJECT}-${VERSION}"

AO_DIST_PATH="${DIST_DIR}/apache.org-dist"
AO_DIST_DEV_PATH="${AO_DIST_PATH}/dev/${PROJECT}"
AO_DIST_RELEASE_PATH="${AO_DIST_PATH}/release/${PROJECT}"

dist_checkout "${AO_DIST_PATH}" "dev/${PROJECT}" "release/${PROJECT}"

# has this been released already?
if ls "${AO_DIST_RELEASE_PATH}/${RELEASE_FILE}".* >/dev/null 2>&1;then
  fail "Files exist as ${AO_DIST_RELEASE_PATH}/${RELEASE_FILE}.*" \
    "This seems to indicate that ${VERSION} has already been released!"
else
  echo "OK: no released tarballs are found."
fi

if ls "${AO_DIST_DEV_PATH}/${VOTE_FILE}".* >/dev/null 2>&1;then
  echo "removing candidate tarballs in ${AO_DIST_DEV_PATH}"
  dist_rm --force "${AO_DIST_DEV_PATH}/${VOTE_FILE}".*
fi
if ls "${AO_DIST_DEV_PATH}/CHANGES_${v_major}.${v_minor}"* >/dev/null 2>&1;then
  echo "removing CHANGES in ${AO_DIST_DEV_PATH}"
  dist_rm --force "${AO_DIST_DEV_PATH}/CHANGES_${v_major}.${v_minor}"*
fi

out=`dist_stat "${AO_DIST_PATH}"`
if test -n "$out"; then
  echo "$out"
  if dist_mode_is_local; then
    echo "DIST_MODE=local: not committing ${AO_DIST_PATH}"
  elif ask_yes_no "Do you want to commit these?"; then
    dist_commit "resetting candidate $FULL_VERSION" "${AO_DIST_PATH}"
  else
    exit 1
  fi
else
  echo "OK: no vote tarballs at dist.apache.org found."
fi

if scm_ref_exists "$CANDIDATE_TAG" candidate; then
  echo "removing `scm_candidate_ref`"
  scm_delete_candidate "resetting candidate $FULL_VERSION"
else
  echo "OK: no candidate exists as `scm_candidate_ref`."
fi

if test -d "$DIST_DIR"; then
  echo "removing local directory: $DIST_DIR"
  rm -rf "$DIST_DIR"
fi
echo "Ok: any trace of candidate $FULL_VERSION should be gone now."