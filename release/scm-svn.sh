# svn backend for the httpd source repository.
#
# Sourced by common-lib.sh; called through the scm_* dispatchers there.
# Populates, next to the neutral SRC_* variables, the historic names
# SVN_URL, SVN_BASE, SVN_SRC and SVN_REV for anything outside these scripts.

scm_svn_assure_commands() {
  type svn >/dev/null 2>&1 || fail "needed command not found: svn"
}

scm_svn_validate() {
  out=`svn stat 2>&1 >/dev/null`
  test -z "$out" || fail "SCM=svn but the local directory is not a SVN checkout:
$out"
}

# Inspect the local directory and populate
# SVN_URL   the absolute url of the local checkout
# SVN_BASE  the base url of the project
# SVN_SRC   the path relative of SVN_BASE of the checkout
# SVN_REV   the revision of the checkout
# and the neutral SRC_URL, SRC_BRANCH, SRC_REV, SRC_REV_SHORT, PROJECT
scm_svn_detect_checkout() {
  SVN_URL=`svn info --show-item url` || fail "unable to determine SVN url"
  test -n "$SVN_URL" || fail "unable to determine SVN url"
  case "$SVN_URL" in
    */trunk)
      SVN_BASE=`echo $SVN_URL | sed -e 's,/trunk,,'`
      SVN_SRC=trunk
      ;;
    */branches/*)
      SVN_BASE=`echo $SVN_URL | sed -e 's,/branches/.*,,'`
      SVN_SRC=`echo $SVN_URL | sed -e 's,.*/branches/,branches/,'`
      ;;
    *)
      fail "unable to detect path in $SVN_URL"
      ;;
  esac
  SVN_REV=`svn info --show-item revision` || fail "unable to determine SVN revision"
  test -n "$SVN_REV" || fail "unable to determine SVN revision"
  if test -z "$PROJECT"; then
    PROJECT=`basename $SVN_BASE`
  fi
  SRC_URL="$SVN_URL"
  SRC_BRANCH="$SVN_SRC"
  SRC_REV="$SVN_REV"
  SRC_REV_SHORT="$SVN_REV"
}

# svn tags are not signed
scm_svn_assure_signing_key() {
  :
}

scm_svn_assure_clean_checkout() {
  out=`svn stat`
  test -z "$out" || fail "local checkout is not clean:
$out
Unversioned files ('?'): remove them by hand (svn stat | grep '^?').
Modified files: 'svn revert -R .' drops all local changes."
}

# the repository path of a candidate/release, relative to SVN_BASE
scm_svn_ref_path() {
  echo "tags/$1"
}

# scm_svn_ref_exists NAME KIND   (KIND: candidate|release, same layout in svn)
scm_svn_ref_exists() {
  svn ls "$SVN_BASE/tags/$1" >/dev/null 2>&1
}

# human readable name of the candidate, for summaries before it exists
scm_svn_candidate_ref() {
  echo "tags/${CANDIDATE_TAG}"
}

scm_svn_describe_candidate() {
  echo "tags/${CANDIDATE_TAG}"
}

scm_svn_create_candidate() {
  svn cp -m "Tag $SVN_SRC@$SVN_REV as $FULL_VERSION" \
    "$SVN_BASE/$SVN_SRC@$SVN_REV" "$SVN_BASE/tags/$CANDIDATE_TAG"
}

# scm_svn_checkout_candidate DIR
scm_svn_checkout_candidate() {
  svn checkout -q "$SVN_BASE/tags/$CANDIDATE_TAG" "$1"
}

# scm_svn_update_candidate DIR
scm_svn_update_candidate() {
  svn update "$1"
}

# scm_svn_status DIR
scm_svn_status() {
  svn stat "$1"
}

# scm_svn_commit_candidate DIR MSG
scm_svn_commit_candidate() {
  svn commit -m "$2" "$1"
}

# nothing to watch after a svn commit; the GitHub mirror will pick it up
scm_svn_ci_hint() {
  :
}

# scm_svn_export NAME DEST   export tags/NAME without SCM metadata into DEST
scm_svn_export() {
  svn export "$SVN_BASE/tags/$1" "$2" > /dev/null
}

# scm_svn_promote_candidate MSG   tags/CANDIDATE_TAG -> tags/RELEASE_TAG
scm_svn_promote_candidate() {
  svn mv -m "$1" "$SVN_BASE/tags/$CANDIDATE_TAG" "$SVN_BASE/tags/$RELEASE_TAG"
}

# scm_svn_delete_candidate MSG
scm_svn_delete_candidate() {
  svn rm -m "$1" "$SVN_BASE/tags/$CANDIDATE_TAG"
}

scm_svn_update_checkout() {
  svn up
}

# scm_svn_commit_checkout MSG   commit the local checkout
scm_svn_commit_checkout() {
  svn commit -m "$1" .
}

# text for the vote email describing where the candidate sources are
scm_svn_candidate_source_text() {
  if test -n "${GIT_WEB_URL}"; then
    cat <<EOT
The candidate source is found at <$SVN_BASE/tags/$CANDIDATE_TAG>
and at <${GIT_WEB_URL}/tree/${CANDIDATE_TAG}>.
EOT
  else
    cat <<EOT
The candidate source is found at <$SVN_BASE/tags/$CANDIDATE_TAG>.
EOT
  fi
}
