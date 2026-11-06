#!/usr/bin/env bash

# Create a release candidate for voting from a local checkout
#
# USAGE: r0-make-candidate.sh rcN | version
# EXAMPLE: r0-make-candidate.sh rc1
#          r0-make-candidate.sh 2.4.49-rc1
#
# This script is called in a built checkout (svn or git, see SCM in env.sh)
# of the branch for which a release candidate shall be made:
# @rcN           the candidate suffix; the version comes from the local sources
# @version       the full version identifier, major.minor.patch(-suffix)
# The argument is required: a candidate without a suffix (a bare 2.4.49)
# is only made when asked for explicitly.
#

#Useful for debugging
#set -x

#Bail when non-zero return codes are encountered
set -e

usage () {
    cat <<EOF 1>&2
usage: $0 [options] rcN|version
  create a release candidate from the local checkout.
  Arguments (one is required):
    rcN            the candidate suffix, e.g. 'rc1'; the version is taken
                   from the local checkout (include/ap_release.h)
    version        the full version as 'm.n.p-suffix', or 'm.n.p' to make a
                   candidate without suffix (asks for confirmation)
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

if test -z "$1"; then
  echo "ERROR: a candidate suffix (rc1) or full version is required; without one this would create a candidate named like the final release" >&2
  usage
fi

source `dirname $0`/common-lib.sh
source `dirname $0`/env.sh

detect_checkout
scm_assure_signing_key
assure_clean_checkout
assure_no_empty_logno
detect_version $1

if test -z "${v_suffix}"; then
  warn "no suffix given: this creates candidate ${FULL_VERSION}, named exactly like the release"
  if ! ask_yes_no "Do you really want a candidate without an rcN suffix?"; then
    exit 1
  fi
fi

DEST_DIR="${DIST_DIR}/${CANDIDATE_TAG}"

# find out which CVEs are ready and will be reporting in this candidate
calc_ready_CVE_DIRS "${DIST_DIR}/pmc"

# if a directory of the candidate already exists at pmc/SECURITY
# something is fishy and we require someone to decide what to fix.
if test -d "${DIST_DIR}/pmc/SECURITY/${PROJECT}-${FULL_VERSION}"; then
  cat <<EOF >&2
${DIST_DIR}/pmc/SECURITY/${PROJECT}-${FULL_VERSION} already exists.
This indicates that the candidate has already been built before
and not been fully removed again. Please verify if the version
number used is correct or if the removal of SECURITY/${PROJECT}-${FULL_VERSION}
was just omitted by mistake.
EOF
  fail "Please correct this and try again."
fi

if test -f include/ap_release.h; then
  if ! grep -e "^#define *AP_SERVER_MAJORVERSION_NUMBER *${v_major}\$" include/ap_release.h >/dev/null 2>&1;then
    fail "AP_SERVER_MAJORVERSION_NUMBER does not match expected ${v_major}"
  fi
  if ! grep -e "^#define *AP_SERVER_MINORVERSION_NUMBER *${v_minor}\$" include/ap_release.h >/dev/null 2>&1;then
    fail "AP_SERVER_MINORVERSION_NUMBER does not match expected ${v_minor}"
  fi
fi

if test -d changes-entries; then
  # template.txt is a permanent fixture and does not count as a pending entry
  if test "$(ls -A changes-entries | grep -v '^template.txt$')"; then
    warn "the 'changes-entries' directory should be empty (apart from template.txt)."
    if ! ask_yes_no "Do you want to continue anyway?"; then
      exit 1
    fi
  fi
fi

# Format CVE list with newlines for readability
if test -n "${CVE_DIRS}"; then
  CVE_COUNT=$(echo "${CVE_DIRS}" | wc -w | tr -d ' ')
  CVE_LIST=$(echo "${CVE_DIRS}" | tr ' ' '\n' | sed 's/^/    /')
  CVE_HEADER="  CVEs (${CVE_COUNT}):"
else
  CVE_COUNT=0
  CVE_LIST="    none"
  CVE_HEADER="  CVEs:"
fi

cat <<EOF
creating release candidate:
  PROJECT: $PROJECT
  VERSION: $FULL_VERSION
  SCM: $SCM
  URL: $SRC_URL
  SOURCE: $SRC_BRANCH@$SRC_REV_SHORT
  DEST: `scm_candidate_ref`
  LOCAL: $DEST_DIR
${CVE_HEADER}
${CVE_LIST}
EOF
if ! ask_yes_no "Is this as expected?"; then
  exit 1
fi

if scm_ref_exists "$CANDIDATE_TAG" candidate; then
  warn "release candidate already exists: `scm_describe_candidate`"
  if ! ask_yes_no "Do you want to continue anyway?"; then
    exit 1
  fi
else
  echo "creating candidate: `scm_candidate_ref`"
  scm_create_candidate
  rm -rf "$DEST_DIR"
fi

if test ! -d "$DEST_DIR"; then
  mkdir -p `dirname "$DEST_DIR"`
  echo "checkout $DEST_DIR"
  scm_checkout_candidate "$DEST_DIR"
else
  echo "updating existing checkout in $DEST_DIR"
  scm_update_candidate "$DEST_DIR"
fi

pushd "$DEST_DIR" >/dev/null

if test -f include/ap_release.h; then
  # Set AP_SERVER_DEVBUILD_BOOLEAN to 0 in include/ap_release.h.
  echo "setting patch version and DEVBUILD in include/ap_release.h"
  perl -pi -e 's/(#define\s+AP_SERVER_DEVBUILD_BOOLEAN\s+)\d/${1}0/g' include/ap_release.h
  if ! grep -e '^#define *AP_SERVER_DEVBUILD_BOOLEAN *0$' include/ap_release.h >/dev/null 2>&1;then
    fail "implementing change to set AP_SERVER_DEVBUILD_BOOLEAN to 0 failed"
  fi
  # Set AP_SERVER_PATCHLEVEL_NUMBER to 0 in include/ap_release.h.
  perl -pi -e 's/(#define\s+AP_SERVER_PATCHLEVEL_NUMBER\s+)\d*/${1}'${v_patch}'/g' include/ap_release.h
  if ! grep -e "^#define *AP_SERVER_PATCHLEVEL_NUMBER *${v_patch}\$" include/ap_release.h >/dev/null 2>&1;then
    fail "setting of AP_SERVER_PATCHLEVEL_NUMBER did not return expected value of ${v_patch}"
  fi
fi

if test -f docs/manual/style/version.ent; then
  # Set ENTITY httpd.patch in docs/manual/style/version.ent.
  echo "setting patch version in docs/manual/style/version.ent"
  perl -pi -e 's/(.*ENTITY httpd.patch ")(\d+)(.*)/${1}'${v_patch}'${3}/g' docs/manual/style/version.ent
  if ! grep -e "ENTITY *httpd.patch *\"${v_patch}\"" docs/manual/style/version.ent >/dev/null 2>&1;then
    fail "setting of ENTITY httpd.patch did not return expected value of ${v_patch}"
  fi
fi

# Ensure the Copyright date reflects the current year
for src in NOTICE docs/manual/style/xsl/common.xsl; do
  current_year=`date +%Y`
  if test -f "$src"; then
    perl -pi -e "s/Copyright \d+ The Apache Software Foundation./Copyright $current_year The Apache Software Foundation./g" "$src"
  fi
done

if test -d docs/manual; then
  # Execute ./build.sh all convmap to ensure that the documentation transformations are up to date.
  echo "rebuilding manuals"
  pushd docs/manual >/dev/null
  #See http://httpd.apache.org/docs-project/docsformat.html for these instructions
  # docs-build stays in svn regardless of SCM
  svn checkout "${SVN_DOCS_BUILD_URL}/trunk" build
  pushd build >/dev/null
  ./build.sh all convmap
  ./build.sh validate-xml
  ./build.sh validate-xhtml
  popd >/dev/null
  rm -rf build
  popd >/dev/null
fi

popd >/dev/null

echo "changes for ${PROJECT}-${FULL_VERSION} in ${DEST_DIR}"
scm_status "${DEST_DIR}"
echo ""
if test -n "${CVE_DIRS}"; then
  note=`local_mode_note " (the candidate commit is pushed to ${SRC_URL}; DIST_MODE=local: the CVE list for pmc stays in ${DIST_DIR}/pmc, not committed)"`
else
  note=`local_mode_note " (the candidate commit is pushed to ${SRC_URL})"`
fi
if ask_yes_no "Do you want to commit these?${note}"; then
  scm_commit_candidate "$DEST_DIR" "Post $FULL_VERSION tag updates"
  echo "release candidate sources created in `scm_describe_candidate`"
  scm_ci_hint
  save_version

  if test -n "${CVE_DIRS}"; then
    CVE_COUNT=$(echo "${CVE_DIRS}" | wc -w | tr -d ' ')
    echo "Saving CVE information for ${PROJECT}-${FULL_VERSION} (${CVE_COUNT} CVEs)"
    mkdir "${DIST_DIR}/pmc/SECURITY/${PROJECT}-${FULL_VERSION}"
    pushd "${DIST_DIR}/pmc/SECURITY/${PROJECT}-${FULL_VERSION}"
    for CVE in $CVE_DIRS; do
      ln -s ../"${CVE}" "${CVE}"
    done
    popd
    pmc_add "${DIST_DIR}/pmc/SECURITY/${PROJECT}-${FULL_VERSION}"

    # Format CVE list for commit message
    CVE_COMMIT_LIST=$(echo "${CVE_DIRS}" | tr ' ' '\n' | sed 's/^/  - /')
    pmc_commit "CVEs included in ${PROJECT}-${FULL_VERSION} (${CVE_COUNT} total):
${CVE_COMMIT_LIST}" "${DIST_DIR}/pmc"
  fi
fi
