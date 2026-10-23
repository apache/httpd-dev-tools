#!/usr/bin/env bash

# Just sign the artifacts, extracted from r1-make-tars.sh.
# They need to be moved from dist/ to e.g. dist/apache.org-dist/dev/httpd/ to be committed.

#Useful for debugging
#set -x

#Bail when non-zero return codes are encountered
set -e

usage () {
    cat <<EOF 1>&2
usage: $0 [options] [version]
  sign the release tars of a release candidate found in the local dist
  directory (created by 'r1-make-tars.sh').
  If no version is given, the current version in the checkout is used.
  Arguments:
    version        as 'm.n.p(-suffix)?', the version to use.
  Options:
    -h             print usage information
    -s sign-user   use gpg/pgp key from 'sign-user'
EOF
  exit 1
}

signing_user=
while getopts "hs:" opt; do
    case $opt in
        h)  usage
            ;;
        s)  signing_user="$OPTARG"
            ;;
    esac
done
shift $((OPTIND-1))

source `dirname $0`/common-lib.sh
source `dirname $0`/env.sh

detect_checkout
detect_version $1

cat <<EOF
signing release tars:
  PROJECT: $PROJECT
  VERSION: $FULL_VERSION
  CANDIDATE: `scm_describe_candidate`
  LOCAL: $DIST_DIR
EOF

EXP_DIRNAME="${PROJECT}-${VERSION}"
EXP_PATH="${DIST_DIR}/${EXP_DIRNAME}"
# almost the same, except using the full version string
TAR_BASENAME="${PROJECT}-${FULL_VERSION}"
TAR_PATH="${DIST_DIR}/${TAR_BASENAME}"

SVN_DIST_URL="https://dist.apache.org/repos/dist/release/httpd"
SVN_DIST_KEYS=KEYS

scm_ref_exists "$CANDIDATE_TAG" candidate ||
  fail "release candidate does not exist: `scm_candidate_ref`"

test -d "$DIST_DIR" || mkdir -p "$DIST_DIR"

build_checksums=1    # create checksum files for tarballs

if test -n "$SVN_DIST_KEYS"; then
  echo " - signing dist files ..."
  sign_dist_files "${signing_user}" "${TAR_PATH}"*.tar.gz "${TAR_PATH}"*.tar.bz2
fi
