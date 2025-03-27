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

SVN_DEST="tags/${FULL_VERSION}-candidate"
SVN_RELEASE="tags/${VERSION}"

echo "You are about to remove any intermediary files for ${PROJECT}-${FULL_VERSION}"
if ! ask_yes_no "Is this what you want?"; then
  exit 1
fi

if svn ls "$SVN_BASE/$SVN_RELEASE" >/dev/null 2>&1 ; then
  fail "release already tagged at $SVN_RELEASE"
else
  echo "OK: $VERSION has not been tagged as release yet."
fi

# the prefixes that tarballs would have
VOTE_FILE="${PROJECT}-${FULL_VERSION}"
RELEASE_FILE="${PROJECT}-${VERSION}"

AO_DIST_PATH="dist/apache.org-dist"
AO_DIST_DEV_PATH="${AO_DIST_PATH}/dev/${PROJECT}"
AO_DIST_RELEASE_PATH="${AO_DIST_PATH}/release/${PROJECT}"

# SVN repository is huge, carefully check out only what we need
rm -rf "${AO_DIST_PATH}"
echo "checking out dist from ${SVN_DIST_URL} ..."
svn checkout --depth=empty "$SVN_DIST_URL" "${AO_DIST_PATH}" >/dev/null
echo "checking out ${AO_DIST_DEV_PATH} ..."
svn update --set-depth immediates --parents "${AO_DIST_DEV_PATH}" >/dev/null
echo "checking out ${AO_DIST_RELEASE_PATH} ..."
svn update --set-depth immediates --parents "${AO_DIST_RELEASE_PATH}" >/dev/null

# has this been released already?
if ls "${AO_DIST_RELEASE_PATH}/${RELEASE_FILE}".* >/dev/null 2>&1;then
  fail "Files exist as ${AO_DIST_RELEASE_PATH}/${RELEASE_FILE}.*" \
    "This seems to indicate that ${VERSION} has already been released!"
else
  echo "OK: no released tarballs are found."
fi

if ls "${AO_DIST_DEV_PATH}/${VOTE_FILE}".* >/dev/null 2>&1;then
  echo "removing candidate tarballs in ${AO_DIST_DEV_PATH}"
  svn rm --force "${AO_DIST_DEV_PATH}/${VOTE_FILE}".*
fi
if ls "${AO_DIST_DEV_PATH}/CHANGES_${v_major}.${v_minor}"* >/dev/null 2>&1;then
  echo "removing CHANGES in ${AO_DIST_DEV_PATH}"
  svn rm --force "${AO_DIST_DEV_PATH}/CHANGES_${v_major}.${v_minor}"*
fi

out=`svn stat "${AO_DIST_PATH}" 2>&1 >/dev/null`
if test -n "$out"; then
  svn stat "${AO_DIST_PATH}"
  if ask_yes_no "Do you want to commit these?"; then
    svn commit -m "resetting candidate $FULL_VERSION" "${AO_DIST_PATH}"
  else
    exit 1
  fi
else
  echo "OK: no vote tarballs at dist.apache.org found."
fi

if svn ls "$SVN_BASE/$SVN_DEST" >/dev/null 2>&1 ; then
  echo "removing subversion $SVN_DEST"
  svn rm -m "resetting candidate $FULL_VERSION" "$SVN_BASE/$SVN_DEST"
else
  echo "OK: no subversion tag exists at $SVN_DEST."
fi

if test -d "$DIST_DIR"; then
  echo "removing local directory: $DIST_DIR"
  rm -rf "$DIST_DIR"
fi
echo "Ok: any trace of candidate $FULL_VERSION should be gone now."