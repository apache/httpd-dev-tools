#!/usr/bin/env bash

#Make sure English is used when formating dates and other things
export LANG=en_US.UTF-8

RELEASE_TOOLS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# backends for the source repository, selected by $SCM (env.sh)
source "${RELEASE_TOOLS_DIR}/scm-svn.sh"
source "${RELEASE_TOOLS_DIR}/scm-git.sh"
# wrappers around the dist.apache.org and pmc svn checkouts, see $DIST_MODE
source "${RELEASE_TOOLS_DIR}/dist-lib.sh"


fail() {
  if test -n "$*"; then
    echo "ERROR: $*" >&2
  fi
  exit 1
}

warn() {
  if test -n "$*"; then
    echo "WARNING: $*" >&2
  fi
  if test "$exit_on_warnings" = 1; then
    exit 1
  fi
}

is_int() {
  x=`expr $1 + 0 2>/dev/null`
  test "$x" = "$1"
}

ask_yes_no() {
  if test "${ALWAYS_YES}" = 1; then
    echo "$* [auto yes]"
    return 0
  fi
  read -r -p "$* [y/N] " response
  case "$response" in
      [yY][eE][sS]|[yY])
          return 0
          ;;
  esac
  return 1
}

assure_commands() {
  # check that all commands that we need are available
  ok=1
  for cmd in svn git jq sed curl perl awk; do
    if ! type "$cmd" >/dev/null 2>&1; then
      echo "ERROR: needed command not found: $cmd" >&2
      ok=0
    fi
  done
  if test "$ok" != 1; then
    fail "please install the missing components."
  fi
  scm_assure_commands
}

########################################
# Source repository abstraction.
#
# Every operation on the httpd source repository goes through one of the
# scm_* functions below, which dispatch at call time to scm_svn_* or
# scm_git_* depending on $SCM (set in env.sh, sourced after this file).
#
# Neutral variables populated by scm_detect_checkout:
#   SRC_URL        where the checkout comes from
#   SRC_BRANCH     'trunk' / 'branches/2.4.x' (svn) or 'trunk' / '2.4.x' (git)
#   SRC_REV        revision number (svn) or commit sha (git)
#   SRC_REV_SHORT  the same, abbreviated for messages
#   PROJECT        project name, e.g. 'httpd'
# and by detect_version:
#   CANDIDATE_TAG  ${FULL_VERSION}-candidate (svn: tags/, git: a branch)
#   RELEASE_TAG    ${VERSION}                (svn: tags/, git: a tag)
# The svn backend keeps setting SVN_URL, SVN_BASE, SVN_SRC and SVN_REV.

# print 'svn' or 'git' depending on the kind of checkout the current
# directory is. The scripts always run from the top of the checkout, where
# svn keeps .svn and git keeps .git (a file for worktrees). Prints nothing
# and returns non-zero when neither or both are present.
scm_detect_type() {
  if test -d .svn -a -e .git; then
    return 2
  elif test -d .svn; then
    echo svn
  elif test -e .git; then
    echo git
  else
    return 1
  fi
}

scm_validate() {
  if test -z "${SCM}"; then
    # detection in env.sh found nothing usable; say why
    if test -d .svn -a -e .git; then
      fail "current directory is both a svn and a git checkout; set SCM=svn or SCM=git explicitly"
    fi
    fail "current directory is neither a svn checkout (.svn) nor a git work tree (.git); run from the top of the checkout"
  fi
  case "${SCM}" in
    svn|git) ;;
    *) fail "SCM must be 'svn' or 'git', not '${SCM}'" ;;
  esac
  "scm_${SCM}_validate" "$@"
}
scm_assure_commands()       { "scm_${SCM}_assure_commands" "$@"; }
scm_detect_checkout()       { "scm_${SCM}_detect_checkout" "$@"; }
scm_assure_clean_checkout() { "scm_${SCM}_assure_clean_checkout" "$@"; }
scm_assure_signing_key()    { "scm_${SCM}_assure_signing_key" "$@"; }
scm_ref_exists()            { "scm_${SCM}_ref_exists" "$@"; }
scm_candidate_ref()         { "scm_${SCM}_candidate_ref" "$@"; }
scm_describe_candidate()    { "scm_${SCM}_describe_candidate" "$@"; }
scm_create_candidate()      { "scm_${SCM}_create_candidate" "$@"; }
scm_checkout_candidate()    { "scm_${SCM}_checkout_candidate" "$@"; }
scm_update_candidate()      { "scm_${SCM}_update_candidate" "$@"; }
scm_status()                { "scm_${SCM}_status" "$@"; }
scm_commit_candidate()      { "scm_${SCM}_commit_candidate" "$@"; }
scm_ci_hint()               { "scm_${SCM}_ci_hint" "$@"; }
scm_export()                { "scm_${SCM}_export" "$@"; }
scm_promote_candidate()     { "scm_${SCM}_promote_candidate" "$@"; }
scm_delete_candidate()      { "scm_${SCM}_delete_candidate" "$@"; }
scm_update_checkout()       { "scm_${SCM}_update_checkout" "$@"; }
scm_commit_checkout()       { "scm_${SCM}_commit_checkout" "$@"; }
scm_candidate_source_text() { "scm_${SCM}_candidate_source_text" "$@"; }

# Inspect the local directory and populate the SRC_* variables (see above)
detect_checkout() {
  scm_validate
  dist_validate
  dist_banner
  scm_detect_checkout
  assure_release_branch
}

# the checkout must be on one of RELEASE_BRANCHES (env.sh)
assure_release_branch() {
  short="${SRC_BRANCH#branches/}"
  for b in ${RELEASE_BRANCHES}; do
    if test "$short" = "$b"; then
      return 0
    fi
  done
  fail "checkout is on '${SRC_BRANCH}', releases are only cut from: ${RELEASE_BRANCHES} (RELEASE_BRANCHES in env.sh)"
}

# untracked_files_found MSG   fatal unless ALLOW_UNTRACKED=1 (r0 -u)
untracked_files_found() {
  if test "${ALLOW_UNTRACKED}" = 1; then
    warn "$1"
  else
    fail "$1"
  fi
}

assure_clean_checkout() {
  scm_assure_clean_checkout
}

assure_no_empty_logno() {
  if find server modules os -name \*.c | \
          xargs grep -C1 --color=always 'APLOGNO()'; then
     fail "local checkout has unfilled APLOGNO"
  fi
}

# given the version input (possibly empty),
# detect/check the version components and set variabels
# VERSION      the version string "major.minor.patch"
# FULL_VERSION $VERSION plus the optional suffix
# v_major      the major integer
# v_minor      the minor integer
# v_patch      the patch integer
# v_suffix     the optional suffix, e.g. 'rc1' or so
detect_version() {
  assure_commands
  version=$1
  case "$version" in
    rc*)
      v_suffix="$version"
      version=""
      ;;
  esac
  if test -z "$version"; then
    # did we record it already?
    if test -f "${DIST_DIR}/VERSION"; then
      # the file carries its own v_suffix; an 'rcN' argument must win over it
      arg_suffix="${v_suffix}"
      source "${DIST_DIR}/VERSION"
      if test -n "${arg_suffix}"; then
        v_suffix="${arg_suffix}"
      fi
    elif test -f include/ap_release.h; then
      # determine version from local files
      v_major=`grep -E '#define\sAP_SERVER_MAJORVERSION_NUMBER' include/ap_release.h | awk '{print $3}'`
      v_minor=`grep -E '#define\sAP_SERVER_MINORVERSION_NUMBER' include/ap_release.h | awk '{print $3}'`
      v_patch=`grep -E '#define\sAP_SERVER_PATCHLEVEL_NUMBER'   include/ap_release.h | awk '{print $3}'`
    else
      fail "unable to determine version in local checkout"
    fi
  else
    v_major=`echo $version | cut -d "." -f 1`
    v_minor=`echo $version | cut -d "." -f 2`
    #Not currently used in this script, but make it available. Support -alpha, -beta -rcX names here
    v_patch=`echo $version | cut -d "." -f 3 | sed -e 's/-.*//'`
    v_suffix=`echo $version | cut -d "." -f 3 | sed -e 's/[^-]*-//'`
    if test "$v_suffix" = "$v_patch"; then
      v_suffix=""
    fi
  fi

  is_int ${v_major} || fail "version major '${v_major}' is not a number"
  is_int ${v_minor} || fail "version minor '${v_minor}' is not a number"
  is_int ${v_patch} || fail "version patch '${v_patch}' is not a number"

  # double check that our checkout matches the version we detected
  if test -f include/ap_release.h; then
    co_v_major=`grep -E '#define\sAP_SERVER_MAJORVERSION_NUMBER' include/ap_release.h | awk '{print $3}'`
    co_v_minor=`grep -E '#define\sAP_SERVER_MINORVERSION_NUMBER' include/ap_release.h | awk '{print $3}'`
    if test "$v_major" != "$co_v_major" -o "$v_minor" != "$co_v_minor"; then
      fail "detect version ${v_major}.${v_minor} does not match checkout verison ${co_v_major}.${co_v_minor}"
    fi
  fi
  VERSION="${v_major}.${v_minor}.${v_patch}"
  FULL_VERSION="${VERSION}"
  if test -n "${v_suffix}"; then
    FULL_VERSION="${VERSION}-${v_suffix}"
  fi
  CANDIDATE_TAG="${FULL_VERSION}-candidate"
  RELEASE_TAG="${VERSION}"

  # a release started with one SCM/DIST_MODE must finish with the same one
  check_recorded_modes
}

# fail if dist/VERSION was written under a different SCM or DIST_MODE than
# the current one. Switching backends is meant to happen between releases.
# SCM_FORCE=1 overrides.
check_recorded_modes() {
  test -f "${DIST_DIR}/VERSION" || return 0
  rec_scm=`sed -n 's/^scm="\(.*\)"$/\1/p' "${DIST_DIR}/VERSION"`
  rec_dist_mode=`sed -n 's/^dist_mode="\(.*\)"$/\1/p' "${DIST_DIR}/VERSION"`
  if test -n "${rec_scm}" -a "${rec_scm}" != "${SCM}"; then
    if test "${SCM_FORCE}" != 1; then
      fail "${DIST_DIR}/VERSION was written with SCM=${rec_scm}, now SCM=${SCM}. Finish the release with the same backend, or set SCM_FORCE=1."
    fi
    warn "${DIST_DIR}/VERSION was written with SCM=${rec_scm}, continuing with SCM=${SCM} (SCM_FORCE=1)"
  fi
  if test -n "${rec_dist_mode}" -a "${rec_dist_mode}" != "${DIST_MODE}"; then
    if test "${SCM_FORCE}" != 1; then
      fail "${DIST_DIR}/VERSION was written with DIST_MODE=${rec_dist_mode}, now DIST_MODE=${DIST_MODE}. A rehearsal must not be half-published; set SCM_FORCE=1 if you really mean it."
    fi
    warn "${DIST_DIR}/VERSION was written with DIST_MODE=${rec_dist_mode}, continuing with DIST_MODE=${DIST_MODE} (SCM_FORCE=1)"
  fi
}

save_version() {
  cat <<EOF > "${DIST_DIR}/VERSION"
v_major="${v_major}"
v_minor="${v_minor}"
v_patch="${v_patch}"
v_suffix="${v_suffix}"
scm="${SCM}"
dist_mode="${DIST_MODE}"
EOF
}

check_autotools() {
  #--------------------------------------------------------------------------
  # autoconf 2.59 or newer
  #
  ac_version=`${AUTOCONF:-autoconf} --version 2>/dev/null|head -1| sed -e 's/^[^0-9]*//' -e 's/[a-z]* *$//'`
  if test -z "$ac_version"; then
    echo "buildcheck: autoconf not found."
    echo "            You need autoconf version 2.59 or newer installed."
    exit 1
  fi
  IFS=.; set $ac_version; IFS=' '
  if test "$1" = "2" -a "$2" -lt "59" || test "$1" -lt "2"; then
    echo "buildcheck: autoconf version $ac_version found."
    echo "            You need autoconf version 2.59 or newer installed."
    echo "            If you have a sufficient autoconf installed, but it"
    echo "            is not named 'autoconf', then try setting the"
    echo "            AUTOCONF environment variable.  (See the INSTALL file"
    echo "            for details.)"
    exit 1
  fi

  echo "check: autoconf version $ac_version (ok)"

  #--------------------------------------------------------------------------
  # autoheader 2.53 or newer
  #
  ah_version=`${AUTOHEADER:-autoheader} --version 2>/dev/null|head -1| sed -e 's/^[^0-9]*//' -e 's/[a-z]* *$//'`
  if test -z "$ah_version"; then
    echo "buildcheck: autoheader not found."
    echo "            You need autoheader version 2.59 or newer installed."
    exit 1
  fi
  IFS=.; set $ah_version; IFS=' '
  if test "$1" = "2" -a "$2" -lt "59" || test "$1" -lt "2"; then
    echo "buildcheck: autoheader version $ah_version found."
    echo "            You need autoheader version 2.59 or newer installed."
    echo "            If you have a sufficient autoheader installed, but it"
    echo "            is not named 'autoheader', then try setting the"
    echo "            AUTOHEADER environment variable.  (See the INSTALL file"
    echo "            for details.)"
    exit 1
  fi

  echo "check: autoheader version $ah_version (ok)"

  #--------------------------------------------------------------------------
  # libtool 1.4.3 or newer
  #
  LIBTOOL_WANTED_MAJOR=1
  LIBTOOL_WANTED_MINOR=5
  LIBTOOL_WANTED_PATCH=10
  LIBTOOL_WANTED_VERSION=1.5.10

  libtool=`which glibtool 2>/dev/null`||true
  if test ! -x "$libtool"; then
    libtool=`which libtool`
  fi
  lt_pversion=`$libtool --version 2>/dev/null|head -1|sed -e 's/^[^0-9]*//' -e 's/[- ].*//'`

  if test -z "$lt_pversion"; then
    echo "buildcheck: libtool not found."
    echo "            You need libtool version $LIBTOOL_WANTED_VERSION or newer installed"
    exit 1
  fi
  lt_version=`echo $lt_pversion|sed -e 's/\([a-z]*\)$/.\1/'`
  IFS=.; set $lt_version; IFS=' '
  lt_status="good"
  if test "$1" = "$LIBTOOL_WANTED_MAJOR"; then
     if test "$2" -lt "$LIBTOOL_WANTED_MINOR"; then
        lt_status="bad"
     elif test ! "$2" -gt "$LIBTOOL_WANTED_MINOR" -a \
          ! -z "$LIBTOOL_WANTED_PATCH"; then
         if test "$3" -lt "$LIBTOOL_WANTED_PATCH"; then
             lt_status="bad"
         fi
     fi
  fi
  if test $lt_status != "good"; then
    echo "buildcheck: libtool version $lt_pversion found."
    echo "            You need libtool version $LIBTOOL_WANTED_VERSION or newer installed"
    exit 1
  fi

  echo "check: libtool version $lt_pversion (ok)"
}

create_dist_checksums() {
  if ! openssl version >/dev/null; then
    fail "unable to find 'openssl' in path"
  fi
  for path in "$@"; do
    pushd `dirname "$path"` >/dev/null
    file=`basename "$path"`
    echo " - create checksums for ${file}"
    openssl sha256 ${file} | sed -e 's#^SHA.*(\(.*\))= \([0-9a-f]*\)$#\2 *\1#' > ${file}.sha256
    openssl sha512 ${file} | sed -e 's#^SHA.*(\(.*\))= \([0-9a-f]*\)$#\2 *\1#' > ${file}.sha512
    popd > /dev/null
  done
}

sign_dist_files() {
  signing_user="$1"; shift

  # check for executables
  gpg2="`which gpg2 2> /dev/null | head -1`"
  gpg="`which gpg 2> /dev/null | head -1`"
  pgp="`which pgp 2> /dev/null | head -1`"

  # there are 3 possible ways to sign, check in preference
  if test -x "${gpg2}"; then
    if test -z "${signing_user}"; then
      args="--default-key"
    else
      args="-u ${signing_user}"
    fi
    for file in "$@"; do
      echo " - gpg2: creating asc signature file for ${file} ..."
      ${gpg2} --armor ${args} --detach-sign ${file}
    done
  elif test -x "${gpg}"; then
    args=""
    if test -n "${signing_user}"; then
      args="-u ${signing_user}"
    fi
    for file in "$@"; do
      echo " - gpg: creating asc signature file for ${file} ..."
      ${gpg} --armor ${args} --detach-sign ${file}
    done
  elif test -x "${pgp}"; then
    args=""
    if test -n "${signing_user}"; then
      args="-u ${signing_user}"
    fi
    for file in "$@"; do
      echo " - pgp: creating asc signature file for ${file} ..."
      ${pgp} -sba ${file} ${args}
    done
  else
    fail "neither PGP nor GnuPG found! Not signing release!"
  fi
}

export_httpd_srclib() {
  apr_tag="$1"
  apu_tag="$2"
  export_dir="$3"
  test -d "$export_dir" || fail "not a directory: $export_dir"

  if test -z "$apr_tag" -o -z "$apu_tag"; then
    if ! curl --version >/dev/null 2>&1;then
      fail "curl must be available to retrieve the latest apr versions."
    fi

    if test "`echo 'test-1.2.3' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+'`" != "1.2.3";then
      fail "your system must support 'grep -o' to retrieve the latest apr versions."
    fi
  fi

  SVNHOST=svn.apache.org
  download_url="https://apr.apache.org/download.cgi"
  echo "Determining latest APR and APU versions from $download_url..."

  if test -z "$apr_tag"; then
    apr_tag=`curl -s $download_url | grep 'APR [0-9].*is the best available version' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+'`
    if test -z "$apr_tag"; then
      fail "failed to determine latest APR version from $download_url"
    else
      echo "  APR: $apr_tag"
    fi
  fi

  if test -z "$apu_tag"; then
    apu_tag=`curl -s $download_url | grep 'APR-util [0-9].*is the best available version' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+'`
    if test -z "$apu_tag"; then
      fail "failed to determine latest APR version from $download_url"
    else
      echo "  APU: $apu_tag"
    fi
  fi

  echo "Exporting apr-${apr_tag} to ${export_dir}/srclib ..."
  svn export https://${SVNHOST}/repos/asf/apr/apr/tags/${apr_tag} "${export_dir}"/srclib/apr > /dev/null || exit 1
  echo "Exporting apr-util-${apu_tag} to ${export_dir}/srclib ..."
  svn export https://${SVNHOST}/repos/asf/apr/apr-util/tags/${apu_tag} "${export_dir}"/srclib/apr-util > /dev/null || exit 1
}

buildconf_httpd_export() {
  export_dir="$1"
  test -d "$export_dir" || fail "not a directory: $export_dir"
  pushd "${export_dir}" > /dev/null
    find . -name autom4te*.cache | xargs rm -rf
    ./buildconf || fail
    find . -name autom4te*.cache | xargs rm -rf
  popd > /dev/null
}

fixup_httpd_export() {
  export_dir="$1"
  test -d "$export_dir" || fail "not a directory: $export_dir"

  find "${export_dir}" -name STATUS | xargs rm -rf
  if test -f "${export_dir}/modules/ssl/ssl_expr_parse.y"; then
      touch "${export_dir}"/modules/ssl/ssl_expr_parse.c
      touch "${export_dir}"/modules/ssl/ssl_expr_parse.h
      touch "${export_dir}"/modules/ssl/ssl_expr_scan.c
  elif test -f "${export_dir}/server/util_expr_parse.y"; then
      touch "${export_dir}"/server/util_expr_parse.c
      touch "${export_dir}"/server/util_expr_parse.h
      touch "${export_dir}"/server/util_expr_scan.c
  else
      warn "found no expression parser to fix in export!"
  fi
  find "${export_dir}"/docs/manual -name \*.xml -o -name \*.xml.\* | xargs rm -rf
  find "${export_dir}"/docs/manual -name \*.xsl -o -name \*.xsl.\* | xargs rm -rf
}

indent_entry() {
  indent="$1"
  indent="${indent:-  *) }"
  while read line; do
     echo "${indent}${line}"
     indent="     "
  done
}

cve_changes() {
  CVE_JSON="$1"
  test -f "${CVE_JSON}" || fail "cve_changes: ${CVE_JSON} not found"
  CVE_ID=`jq -r .cveMetadata.cveId "${CVE_JSON}"`
  CVE_TITLE=`jq -r .containers.cna.title "${CVE_JSON}"`
  test -n "${CVE_ID}" -a "${CVE_ID}" != "null" || fail "CVE ID missing in ${CVE_JSON}"
  CVE_DESCR=`jq -r '.containers.cna.descriptions[0].value' "${CVE_JSON}"`
  cat << EOF | fold -sw 65 | indent_entry
SECURITY: ${CVE_ID}: ${CVE_TITLE} (cve.mitre.org)
${CVE_DESCR}

EOF
  CVE_CREDIT=`jq -r '.containers.cna.credits[0].value' "${CVE_JSON}"`
  if test -n "${CVE_CREDIT}" -a "${CVE_CREDIT}" != "null"; then
    cat << EOF | fold -sw 65 | indent_entry "     "
Credits: ${CVE_CREDIT}

EOF
  fi
}

add_changes_entry() {
  CHANGES="$1"
  CVE_JSON="$2"
  test -f "${CHANGES}" || fail "add_changes_entry: changes ${CHANGES} not found"

  cp "${CHANGES}" "${CHANGES}.tmp" ;
  cve_changes "${CVE_JSON}" > "${CHANGES}.entry.tmp"
  # Insert the entry at the top of the first "Changes with Apache" section,
  # or at the end of the file when that section has no entries yet.
  # Exits non-zero when no section was found, rather than dropping the entry.
  if ! awk -v fname="${CHANGES}.entry.tmp" \
    'function add_entry() {
        while ((getline line < fname) > 0) {
          if (! (line ~ /^ *$/)){print line}
        }
        printf "\n"; done = 1
      }
      BEGIN{done = 0; active = 0} done == 0 && active == 0 && /^Changes with Apache /{
        active = 1; print; next};
      /^( *\*|Changes with Apache )/ && active == 1 && done == 0 {
        rec=$0; add_entry(); print rec; active = 0; next
      } //;
      END { if (active == 1 && done == 0) add_entry(); if (done == 0) exit 1 }' \
      "${CHANGES}".tmp > "${CHANGES}"; then
    mv "${CHANGES}".tmp "${CHANGES}"
    rm -f "${CHANGES}.entry.tmp"
    fail "add_changes_entry: no 'Changes with Apache' section in ${CHANGES}"
  fi
  rm -f "${CHANGES}".tmp "${CHANGES}.entry.tmp"
}

stage_checkout_release() {
  # make sure we are up-to-date
  scm_update_checkout
  # calculate the next patch version
  is_int ${v_patch} || fail "version patch '${v_patch}' is not a number"
  next_patch=`expr ${v_patch} + 1`
  NEXT_VERSION="${v_major}.${v_minor}.${next_patch}"

  # Add the corresponding version placeholder in CHANGES.
  perl -pi -e "s{(.*coding: utf-8.*)}{\$1\nChanges with Apache ${NEXT_VERSION}\n}" CHANGES
  # Note the tag date in the STATUS file.
  if test -f STATUS; then
    date_string=`date '+%B %d, %Y'`
    perl -pi -e '
      if(/^(\s+)('${VERSION}'\s+):/){
        $size = length $2;
        $newline1 = sprintf("${1}%-${size}s", "'${NEXT_VERSION}'") . ": In development\n";
        $newline2 = sprintf("${1}%-${size}s", "'${VERSION}'") . ": Released on '"${date_string}"'\n";
        $_="${newline1}${newline2}";
      }
      ' STATUS
  fi

  # set the patch number of the next version
  if test -f include/ap_release.h; then
    echo "setting patch number in include/ap_release.h"
    perl -pi -e 's/(#define\s+AP_SERVER_PATCHLEVEL_NUMBER\s+)\d*/${1}'${next_patch}'/g' include/ap_release.h
    if ! grep -e "^#define *AP_SERVER_PATCHLEVEL_NUMBER *${next_patch}\$" include/ap_release.h >/dev/null 2>&1;then
      fail "setting of AP_SERVER_PATCHLEVEL_NUMBER did not return expected value of ${next_patch}"
    fi
  fi

  # Ensure the Copyright date reflects the current year
  current_year=`date +%Y`
  for src in NOTICE docs/manual/style/xsl/common.xsl; do
    if test -f "$src"; then
      perl -pi -e "s/Copyright \d+ The Apache Software Foundation./Copyright $current_year The Apache Software Foundation./g" "$src"
    fi
  done

  if test -d docs/manual; then
    if test -f docs/manual/style/version.ent; then
      # Set ENTITY httpd.patch in docs/manual/style/version.ent.
      echo "setting patch version in docs/manual/style/version.ent"
      perl -pi -e 's/(.*ENTITY httpd.patch ")(\d+)(.*)/${1}'${next_patch}'${3}/g' docs/manual/style/version.ent
      if ! grep -e "ENTITY *httpd.patch *\"${next_patch}\"" docs/manual/style/version.ent >/dev/null 2>&1;then
        fail "setting of ENTITY httpd.patch did not return expected value of ${next_patch}"
      fi
    fi

    echo "rebuilding manuals"
    pushd docs/manual >/dev/null
    #See http://httpd.apache.org/docs-project/docsformat.html for these instructions
    if test -d build; then
      svn update build
    else
      svn checkout "${SVN_DOCS_BUILD_URL}/trunk" build
    fi
    pushd build >/dev/null
    ./build.sh all convmap
    ./build.sh validate-xml
    ./build.sh validate-xhtml
    popd >/dev/null
    popd >/dev/null
  fi
}

checkout_pmc() {
  pmc_checkout "$1"
}

calc_ready_CVE_DIRS() {
  dest="$1"
  checkout_pmc "${dest}"
  pushd "${dest}/SECURITY" >/dev/null
  CVE_SUBDIRS=`./tools/readiness.sh -n | fgrep '[OK]'| awk '{print $2}' | sort `
  popd >/dev/null

  cves_ok=1
  CVE_DIRS=""
  for CVE in $CVE_SUBDIRS; do
    CVE=`basename "${CVE}"`
    if test -f "${dest}/SECURITY/${CVE}/CVE.json"; then
      CVE_DIRS="$CVE_DIRS ${CVE}"
    else
      echo "ERROR: CVE ${CVE} does not have a CVE.json file."
      cves_ok=0
    fi
  done
  if test "${cves_ok}" != 1; then
    fail "Please correct the files mentioned."
  fi
}

get_version_CVE_DIRS() {
  dest="$1"
  checkout_pmc "${dest}"
  cve_version_dir="${dest}/SECURITY/${PROJECT}-${FULL_VERSION}"
  if ! test -d "${cve_version_dir}"; then
    echo "CVE Directory '${cve_version_dir}' does not exist. If you expected CVEs, ^C to interrupt"
    sleep 30
    return
  fi
  cves_ok=1
  CVE_DIRS=""
  for CVE in "${cve_version_dir}"/*; do
    if ! test -d "${CVE}"; then
      continue
    fi
    CVE=`basename "${CVE}"`
    if test -f "${dest}/SECURITY/${CVE}/CVE.json"; then
      CVE_DIRS="$CVE_DIRS ${CVE}"
    else
      echo "ERROR: CVE ${CVE} does not have a CVE.json file."
      cves_ok=0
    fi
  done
  if test "${cves_ok}" != 1; then
    fail "Please correct the files mentioned."
  fi
}
