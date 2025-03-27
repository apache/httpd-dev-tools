#!/usr/bin/env bash

# Create the release tars from a svn candidate tag
#
# USAGE: r1-make-tars.sh [version]
# EXAMPLE: r1-make-tars.sh 2.4.49
#
# Create the tar files for a release candidate svn tag
# @version       the version identifier, major.minor.patch, to use. If not given
#                it will determine the version from the local sources

#Useful for debugging
#set -x

#Bail when non-zero return codes are encountered
set -e

usage () {
    cat <<EOF 1>&2
usage: $0 [options] [version]
  create the release tars from a SVN candidate. The candidate is expected
  to be found in SVN at 'tags/$version-candidate', as prepared by the
  'make-candidate.sh' script.
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

SVN_DEST="tags/${FULL_VERSION}-candidate"

cat <<EOF
creating release tars:
  PROJECT: $PROJECT
  VERSION: $FULL_VERSION
  CANDIDATE: $SVN_BASE/$SVN_DEST
  LOCAL: $DIST_DIR
EOF

EXP_DIRNAME="${PROJECT}-${VERSION}"
EXP_PATH="${DIST_DIR}/${EXP_DIRNAME}"
# almost the same, except using the full version string
TAR_BASENAME="${PROJECT}-${FULL_VERSION}"
TAR_PATH="${DIST_DIR}/${TAR_BASENAME}"

svn ls "$SVN_BASE/$SVN_DEST" >/dev/null 2>&1 ||
  fail "release candidate does not exist in SVN: $SVN_DEST"

test -d "$DIST_DIR" || mkdir -p "$DIST_DIR"

echo "purging any previous leftovers related to $EXP_PATH"
rm -rf "${EXP_PATH}"
rm -f "${DIST_DIR}/${EXP_DIRNAME}"*.tar.*

echo "exporting $SVN_DEST to $EXP_PATH"
svn export "$SVN_BASE/$SVN_DEST" "${EXP_PATH}" > /dev/null

build_checksums=1    # create checksum files for tarballs

case "$PROJECT" in
  httpd)
    apr_tag=""           # empty means latest version is looked up
    apu_tag=""           # empty means latest version is looked up
    SVN_DIST_URL="https://dist.apache.org/repos/dist/release/httpd"
    SVN_DIST_KEYS=KEYS
    case "${v_major}.${v_minor}" in
      2.4)
        # overrride vars for this version
        ;;
      2.5)
        # overrride vars for this version
        ;;
    esac
    echo "Preparing httpd export for being built..."

    check_autotools
    export_httpd_srclib "$apr_tag" "$apu_tag" "${EXP_PATH}"
    buildconf_httpd_export "${EXP_PATH}"
    fixup_httpd_export "${EXP_PATH}"

    echo "Separating out srclib tarballs"
    rm -rf "${EXP_PATH}-deps"
    mkdir -p "${EXP_PATH}-deps"/${EXP_DIRNAME}/srclib
    mv "${EXP_PATH}/srclib/apr" "${EXP_PATH}-deps/${EXP_DIRNAME}/srclib"
    mv "${EXP_PATH}/srclib/apr-util" "${EXP_PATH}-deps/${EXP_DIRNAME}/srclib"
    tar -C "${EXP_PATH}-deps" -cf ${TAR_PATH}-deps.tar "${EXP_DIRNAME}"
    gzip -9 --to-stdout "${TAR_PATH}-deps.tar" > "${TAR_PATH}-deps.tar.gz"
    bzip2 -9 "${TAR_PATH}-deps.tar"
    ;;

  *)
    warn "'$PROJECT' is an unknown project."
    ;;
esac


echo "building dist tarballs ..."
tar  -C "${DIST_DIR}" -cf "${TAR_PATH}".tar "${EXP_DIRNAME}"
gzip -9 --to-stdout "${TAR_PATH}".tar > "${TAR_PATH}".tar.gz
bzip2 -9 "${TAR_PATH}".tar

if test "$build_checksums" = 1; then
  echo " - create dist checksums ..."
  create_dist_checksums "${TAR_PATH}"*.tar.gz "${TAR_PATH}"*.tar.bz2
fi

if test -n "$SVN_DIST_KEYS"; then
  echo " - signing dist files ..."
  sign_dist_files "${signing_user}" "${TAR_PATH}"*.tar.gz "${TAR_PATH}"*.tar.bz2
fi

save_version
