#!/usr/bin/env bash

# Stage a release candidate that has passed voting
#
# USAGE: r3-push-release-tars.sh [version]
# version: x.y.z (example 2.4.38)

#Useful for debugging
#set -x

#Bail when non-zero return codes are encountered
set -e

usage () {
    cat <<EOF 1>&2
usage: $0 [options] [version]
  release a candidate that has passed voting. The tars need
  to exist at ${SVN_DIST_URL}/dev/ (put there by push-tars.sh).
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
scm_assure_signing_key
detect_version $1

scm_ref_exists "$CANDIDATE_TAG" candidate ||
  fail "release candidate does not exist: `scm_candidate_ref`"

EXP_DIRNAME="${PROJECT}-${VERSION}"
EXP_PATH="${DIST_DIR}/${EXP_DIRNAME}"
# almost the same, except using the full version string
TAR_BASENAME="${PROJECT}-${FULL_VERSION}"
TAR_PATH="${DIST_DIR}/${TAR_BASENAME}"

#Ensure scratch space is in a state we are ready to work with
AO_DIST_PATH="${DIST_DIR}/apache.org-dist"
AO_DIST_DEV_PATH="${AO_DIST_PATH}/dev/${PROJECT}"
AO_DIST_RELEASE_PATH="${AO_DIST_PATH}/release/${PROJECT}"

dist_checkout "${AO_DIST_PATH}" "dev/${PROJECT}" "release/${PROJECT}"

echo "updating Announcement files ..."
#Likely a duplicate of what we did above, but be safe... force version number in announcements
perl -pi -e "s/${v_major}\.${v_minor}\.\d+/$VERSION/g" "${AO_DIST_RELEASE_PATH}/Announcement${v_major}.${v_minor}".*

#Ensure the right date is in announcement file
release_date=`LC_TIME=en_US date "+%B %d, %Y"`
perl -pi -e "s/^   (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec).*/   $release_date/" "${AO_DIST_RELEASE_PATH}"/Announcement${v_major}.${v_minor}.*

echo "moving voted tars ${AO_DIST_DEV_PATH}/${PROJECT}-${FULL_VERSION}.tar.*"
#Do an SVN move of the files to retain history
dist_mv "${AO_DIST_DEV_PATH}/${PROJECT}-${FULL_VERSION}".tar.* "${AO_DIST_RELEASE_PATH}"/
if test "${VERSION}" != "${FULL_VERSION}"; then
  # releasing a version with a suffix, e.g. -rc1. rename to just version
  echo "renaming ${FULL_VERSION} files to ${VERSION}"
  for file in "${AO_DIST_RELEASE_PATH}/${PROJECT}-${FULL_VERSION}".tar.*; do
    dest=`echo $file | sed -e "s/${FULL_VERSION}/${VERSION}/"`
    dist_mv "$file" "$dest"
  done
  # fix the filenames in the hash files (PR65665)
  echo "fixing ${FULL_VERSION} filename to ${VERSION} in hash files"
  for file in "${AO_DIST_RELEASE_PATH}/${PROJECT}-${VERSION}".tar.*.sha*;  do
    perl -pe "s/${FULL_VERSION}/${VERSION}/" -i $file
  done
fi
# CHANGES_${VERSION} and CHANGES_${v_major}.${v_minor} stay in dev. They lack
# the CVE information, and anything fetched from release now may be cached by
# the CDN, so r4-stage-release.sh moves them once the CVEs are folded in.

# remove dependency tars from dev
if ls "${AO_DIST_DEV_PATH}/httpd-${FULL_VERSION}-deps".tar.* >/dev/null 2>&1;then
  dist_rm --force "${AO_DIST_DEV_PATH}/httpd-${FULL_VERSION}-deps".tar.*
fi

#Note we don't delete the Announce files since it is our template

echo ""
echo "changes ready for commit in: ${AO_DIST_PATH}"
echo "----------------------------"
dist_stat "${AO_DIST_PATH}"
if dist_mode_is_local; then
  echo "DIST_MODE=local: not committing ${AO_DIST_PATH}"
elif ask_yes_no "Do you want to commit these?"; then
  dist_commit "Add release $PROJECT-$VERSION from voted $FULL_VERSION" "${AO_DIST_PATH}"
else
  exit 1
fi

# As a last step, turn the candidate into the release
# (svn: move tags/X-candidate to tags/X; git: tag the candidate branch's
# commit as X and delete the branch)
echo "promoting `scm_candidate_ref` to release ${RELEASE_TAG}"
scm_promote_candidate "release $VERSION from voted $FULL_VERSION"

save_version
