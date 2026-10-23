#!/usr/bin/env bash

# Publish a staged release to the world
#
# USAGE: r4-stage-release.sh [version]
# version: x.y.z (example 2.4.38)

#Useful for debugging
#set -x

#Bail when non-zero return codes are encountered
set -e

usage () {
    cat <<EOF 1>&2
usage: $0 [options] [version]
  incorporate security related information into the release files
  and prepare pmc, website and local checkouts for changes.
  Does not commit anything, just prepares.
  If no version is given, the current version in the checkout is used.
  Arguments:
    version        as 'm.n.p(-suffix)?', the version to use.
  Options:
    -h             print usage information
    -n             dry run, do not exit on failures
    -y             never ask, always assume yes
EOF
  exit 1
}

fail_not_dry() {
  if test -z "${DRY_RUN}"; then
    fail "$@"
  fi
  echo "IGNORED ERROR: $@"
}

fake_changes() {
  changes="$1"
  cat <<EOF > "${changes}"
                                                         -*- coding: utf-8 -*-
Changes with Apache ${VERSION}

EOF
}

DRY_RUN=""
while getopts "hny" opt; do
    case $opt in
        h)  usage
            ;;
        n)  DRY_RUN="1"
            ;;
        y)  ALWAYS_YES=1
            ;;
    esac
done
shift $((OPTIND-1))

source `dirname $0`/common-lib.sh
source `dirname $0`/env.sh

detect_checkout
assure_clean_checkout

detect_version $1

scm_ref_exists "$RELEASE_TAG" release ||
  fail_not_dry "release ${RELEASE_TAG} does not exist in ${SRC_URL}"

AO_DIST_PATH="${DIST_DIR}/apache.org-dist"
AO_DIST_DEV_PATH="${AO_DIST_PATH}/dev/${PROJECT}"
AO_DIST_RELEASE_PATH="${AO_DIST_PATH}/release/${PROJECT}"

DIST_SITEPATH="${DIST_DIR}/site"

TAR_BASENAME="${PROJECT}-${VERSION}"

dist_checkout "${AO_DIST_PATH}" "release/${PROJECT}" "dev/${PROJECT}"

# r3-push-release-tars.sh leaves the CHANGES files in dev, so that they are
# published in release only together with the CVE information added below.
if test -f "${AO_DIST_DEV_PATH}/CHANGES_${VERSION}"; then
  echo "moving ${AO_DIST_DEV_PATH}/CHANGES_${VERSION} to release"
  dist_mv "${AO_DIST_DEV_PATH}/CHANGES_${VERSION}" "${AO_DIST_RELEASE_PATH}"/ >/dev/null
fi
if test -f "${AO_DIST_DEV_PATH}/CHANGES_${v_major}.${v_minor}"; then
  echo "copying ${AO_DIST_DEV_PATH}/CHANGES_${v_major}.${v_minor} to release"
  #We cannot move since these exist in the destination
  cp "${AO_DIST_DEV_PATH}/CHANGES_${v_major}.${v_minor}" "${AO_DIST_RELEASE_PATH}"/
  dist_rm --force "${AO_DIST_DEV_PATH}/CHANGES_${v_major}.${v_minor}" >/dev/null
fi

if ! ls "${AO_DIST_RELEASE_PATH}/${TAR_BASENAME}".tar.* >/dev/null 2>&1; then
  fail_not_dry "release tar not found: ${AO_DIST_RELEASE_PATH}/${TAR_BASENAME}.tar.*"
fi
if test ! -f "${AO_DIST_RELEASE_PATH}/CHANGES_${v_major}.${v_minor}"; then
  fail_not_dry "${AO_DIST_RELEASE_PATH}/CHANGES_${v_major}.${v_minor} not found."
  fake_changes "${AO_DIST_RELEASE_PATH}/CHANGES_${v_major}.${v_minor}"
fi
if test ! -f "${AO_DIST_RELEASE_PATH}/CHANGES_${VERSION}"; then
  fail_not_dry "${AO_DIST_RELEASE_PATH}/CHANGES_${VERSION} not found."
  fake_changes "${AO_DIST_RELEASE_PATH}/CHANGES_${VERSION}"
fi


# checkout/update pmc and get dir dir names that have
# been recorded there for this release
get_version_CVE_DIRS "${DIST_DIR}/pmc"
if test -n "${CVE_DIRS}"; then
  echo "adding CVEs: ${CVE_DIRS}"
  ALL_CHANGES="CHANGES
    ${AO_DIST_RELEASE_PATH}/CHANGES_${v_major}.${v_minor}
    ${AO_DIST_RELEASE_PATH}/CHANGES_${VERSION}"
  for changes in $ALL_CHANGES; do
    for CVE in $CVE_DIRS; do
      add_changes_entry "$changes" "${DIST_DIR}/pmc/SECURITY/${CVE}/CVE.json"
    done
  done
  # make sure every CVE made it into every CHANGES file
  for CVE in $CVE_DIRS; do
    CVE_ID=`jq -r .cveMetadata.cveId "${DIST_DIR}/pmc/SECURITY/${CVE}/CVE.json"`
    for changes in $ALL_CHANGES; do
      grep -qF "SECURITY: ${CVE_ID}:" "$changes" ||
        fail_not_dry "${CVE_ID} is missing from ${changes}"
    done
  done
fi


# Update the latest version pointer
dist_rm --force "${AO_DIST_RELEASE_PATH}/CURRENT-IS-${v_major}.${v_minor}"* >/dev/null
touch "${AO_DIST_RELEASE_PATH}/CURRENT-IS-${VERSION}"
dist_add "${AO_DIST_RELEASE_PATH}/CURRENT-IS-${VERSION}" >/dev/null

# we should only keep one release in our dist repository,
# remove the previous one if it exists
prev_patch=`expr ${v_patch} - 1`
PREV_VERSION="${v_major}.${v_minor}.${prev_patch}"
for i in "${AO_DIST_RELEASE_PATH}/${PROJECT}-${PREV_VERSION}".tar.* \
         "${AO_DIST_RELEASE_PATH}/CHANGES_${v_major}.${v_minor}.${prev_patch}"; do
  test -f "$i" && dist_rm "$i"
done


########################################
# checkout and patch the project website
test -n "${GIT_SITE_URL}" || fail "site URL not given"
test -n "${DIST_SITEPATH}" || fail "site path not given"
rm -rf "${DIST_SITEPATH}"
git clone "${GIT_SITE_URL}" "${DIST_SITEPATH}"

#Update the site content with the new release date and version
echo "updating site content for ${PROJECT}-${VERSION}"
iso_date=`date +%Y-%m-%d`
timeline_timestamp=`date -u +%Y-%m-%dT12:00:00.000Z`
perl -pi -e "s/${v_major}\.${v_minor}\.\d+/${VERSION}/g" "${DIST_SITEPATH}"/content/doap.rdf
perl -pi -e "s|<created>.*|<created>$iso_date</created>|g" "${DIST_SITEPATH}"/content/doap.rdf

#Modify the home page by replacing the date and the version string
perl -pi -e "s|Apache httpd $major.$minor.* Released <span>.*</span>|Apache httpd ${VERSION} Released <span>$iso_date</span>|g" "${DIST_SITEPATH}"/content/index.md
perl -pi -e "s/${v_major}\.${v_minor}\.\d+/${VERSION}/g" "${DIST_SITEPATH}"/content/index.md

#Downloads page
perl -pi -e "s/${v_major}\.${v_minor}\.\d+/${VERSION}/g" "${DIST_SITEPATH}"/content/download.md
perl -pi -e "s/\\d{4}-\\d{2}-\\d{2}/$iso_date/ if /${VERSION}/" "${DIST_SITEPATH}"/content/download.md
if ! grep -e "# Apache HTTP Server ${VERSION} (httpd): ${VERSION}.*<span>$iso_date</span>" "${DIST_SITEPATH}"/content/download.md >/dev/null;then
  fail "Failed to update the release version and/or date in download.md"
fi

if test -n "${CVE_DIRS}"; then
    echo "adding timeline entry to CVEs and copy to site"
    TIMELINE_ENTRY='{"lang":"eng","time":"'"${timeline_timestamp}"'","value":"'"${VERSION}"' released"}'

    # Validation pass
    for CVE in $CVE_DIRS; do
      CVE_JSON="${DIST_DIR}/pmc/SECURITY/${CVE}/CVE.json"
      test -f "$CVE_JSON" || fail "not found: ${CVE_JSON}"
      CVE_ID=`jq -r .cveMetadata.cveId "${CVE_JSON}"`
      if ! jq -e 'any(.containers.cna.timeline[]?; .value | contains("fixed in 2.4.x"))' < $CVE_JSON; then
         fail "${CVE_JSON} doesn't have any 'fixed in 2.4.x' timeline when staging content, so it will not be on the website"
      fi
    done

    for CVE in $CVE_DIRS; do
      CVE_JSON="${DIST_DIR}/pmc/SECURITY/${CVE}/CVE.json"
      test -f "$CVE_JSON" || fail "not found: ${CVE_JSON}"
      CVE_ID=`jq -r .cveMetadata.cveId "${CVE_JSON}"`
      test -n "${CVE_ID}" -a "${CVE_ID}" != "null" || fail "CVE ID missing in ${CVE_JSON}"
      echo "adding ${CVE_ID}"
      # add a timeline entry for the release and copy to website
      rm -f "${CVE_JSON}".tmp
      jq --indent 2 '.containers.cna.timeline[.containers.cna.timeline|length] |= . + '"${TIMELINE_ENTRY}" "${CVE_JSON}" > "${CVE_JSON}".tmp
      mv "${CVE_JSON}".tmp "${CVE_JSON}"
      cp "${CVE_JSON}" "${DIST_SITEPATH}"/content/security/json/${CVE_ID}.json
    done
fi

echo "adding site changes"
(cd "${DIST_SITEPATH}" && git add .)

# finally, move CVEs we handled to resolved
if test -n "${CVE_DIRS}"; then
  echo "moving CVEs to pmc/resolved ..."
  for CVE in $CVE_DIRS; do
    pmc_mv "${DIST_DIR}/pmc/SECURITY/${CVE}" "${DIST_DIR}/pmc/resolved/" >/dev/null
  done
  if test -d "${DIST_DIR}/pmc/SECURITY/${PROJECT}-${FULL_VERSION}"; then
    pmc_rm "${DIST_DIR}/pmc/SECURITY/${PROJECT}-${FULL_VERSION}"
  fi
fi

########################################
# stage changes in the local branch checkout
# step the patch level and update local files for the next version
stage_checkout_release

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

save_version
