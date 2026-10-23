#!/usr/bin/env bash

# Compare two httpd source tarballs (e.g. the last release and a candidate)
# and sort the differences into what is expected from one release to the
# next and what deserves a look.
#
# USAGE: compare-tarballs.sh [options] OLD NEW
#   OLD, NEW   path or https URL of a .tar.gz / .tar.bz2 source tarball
# Options:
#   -w DIR     work directory (kept); default: a temporary one, removed
#   -s URL     svn base of the project for cross-checks, default
#              https://svn.apache.org/repos/asf/httpd/httpd; files only in
#              one tarball are looked up in branches/M.N.x and tags/OLDVER
#              to tell "added/removed upstream" from "lost by the export"
#   -S         skip the svn cross-checks
#   -v         list every file in every category (default: first 15 each)
#   -d         also print a diff for files in the scrutiny categories
#   -h         usage
#
# Exit status is 0 when nothing needs scrutiny, 2 otherwise, 1 on errors.

set -e
export LC_ALL=C    # byte-wise text handling; the docs include euc-kr etc.

usage() {
  sed -n '3,/^$/p' "$0" | sed -e 's/^# \{0,1\}//' >&2
  exit 1
}
fail() { echo "ERROR: $*" >&2; exit 1; }

WORK=""; VERBOSE=0; SHOWDIFF=0; LIMIT=15
SVN_BASE="https://svn.apache.org/repos/asf/httpd/httpd"
while getopts "hw:s:Svd" opt; do
  case $opt in
    h) usage ;;
    w) WORK="$OPTARG" ;;
    s) SVN_BASE="$OPTARG" ;;
    S) SVN_BASE="" ;;
    v) VERBOSE=1 ;;
    d) SHOWDIFF=1 ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))
test $# -eq 2 || usage
OLD_SRC="$1"; NEW_SRC="$2"

for cmd in curl tar perl diff cmp comm; do
  type "$cmd" >/dev/null 2>&1 || fail "needed command not found: $cmd"
done
if test -n "$SVN_BASE" && ! type svn >/dev/null 2>&1; then
  echo "svn not found, skipping the svn cross-checks (-S)" >&2
  SVN_BASE=""
fi

if test -z "$WORK"; then
  WORK=`mktemp -d -t compare-tarballs`
  trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK"
WORK=`cd "$WORK" && pwd`

fetch_tarball() {   # SRC DEST
  case "$1" in
    http://*|https://*)
      echo "downloading $1 ..." >&2
      curl -fsSL -o "$2" "$1" || fail "download failed: $1"
      ;;
    *)
      test -f "$1" || fail "no such file: $1"
      cp "$1" "$2"
      ;;
  esac
}
tar_flag() { case "$1" in *.tar.bz2) echo j;; *.tar.xz) echo J;; *) echo z;; esac; }
ext_of()   { case "$1" in *.tar.bz2) echo tar.bz2;; *.tar.xz) echo tar.xz;; *) echo tar.gz;; esac; }
unpack() {   # TARBALL DIR -> prints the single top-level directory
  rm -rf "$2"; mkdir -p "$2"
  tar -x"$(tar_flag "$1")"f "$1" -C "$2"
  tops=`ls -A "$2"`
  test "`echo "$tops" | wc -l | tr -d ' '`" = 1 || fail "$1 does not contain a single top-level directory: $tops"
  echo "$2/$tops"
}

OLD_TAR="$WORK/old.$(ext_of "$OLD_SRC")"
NEW_TAR="$WORK/new.$(ext_of "$NEW_SRC")"
fetch_tarball "$OLD_SRC" "$OLD_TAR"
fetch_tarball "$NEW_SRC" "$NEW_TAR"
OLD_ROOT=$(unpack "$OLD_TAR" "$WORK/old")
NEW_ROOT=$(unpack "$NEW_TAR" "$WORK/new")
OLD_TOP=`basename "$OLD_ROOT"`; NEW_TOP=`basename "$NEW_ROOT"`
OLD_VER=`echo "$OLD_TOP" | sed -e 's/^[^0-9]*//'`
NEW_VER=`echo "$NEW_TOP" | sed -e 's/^[^0-9]*//'`
MAJMIN=`echo "$NEW_VER" | cut -d. -f1,2`

# ---- tar level metadata ------------------------------------------------------
tar_owners() {
  tar -t"$(tar_flag "$1")"vf "$1" | awk '{print $3}' | sort | uniq -c | sort -rn | head -3 | awk '{printf "%s(%s) ", $2, $1}'
}
OLD_OWNERS=$(tar_owners "$OLD_TAR")
NEW_OWNERS=$(tar_owners "$NEW_TAR")

# ---- inventories: "mode<TAB>type<TAB>path" in one pass per tree --------------
TAB=`printf '\t'`
inventory() {   # DIR -> lines "MODE\tTYPE\tPATH" (TYPE f/l), sorted by path
  ( cd "$1" && find . \( -type f -o -type l \) -print0 |
    perl -0ne 'chomp; s,^\./,,; my @s = lstat($_); printf "%04o\t%s\t%s\n", $s[2] & 07777, (-l $_ ? "l" : "f"), $_' |
    sort -t "$TAB" -k3 )
}
inventory "$OLD_ROOT" > "$WORK/old.inv"
inventory "$NEW_ROOT" > "$WORK/new.inv"
cut -f3 "$WORK/old.inv" > "$WORK/old.files"
cut -f3 "$WORK/new.inv" > "$WORK/new.files"
( cd "$OLD_ROOT" && find . -type d -empty | sed -e 's,^\./,,' | sort ) > "$WORK/old.emptydirs"
( cd "$NEW_ROOT" && find . -type d -empty | sed -e 's,^\./,,' | sort ) > "$WORK/new.emptydirs"
comm -23 "$WORK/old.files" "$WORK/new.files" > "$WORK/only.old"
comm -13 "$WORK/old.files" "$WORK/new.files" > "$WORK/only.new"
comm -12 "$WORK/old.files" "$WORK/new.files" > "$WORK/common"
comm -23 "$WORK/old.emptydirs" "$WORK/new.emptydirs" > "$WORK/emptydirs.only.old"
comm -13 "$WORK/old.emptydirs" "$WORK/new.emptydirs" > "$WORK/emptydirs.only.new"
# modes of common files, side by side: PATH OLDMODE OLDTYPE NEWMODE NEWTYPE (tabs)
join -t "$TAB" -j 3 -o 0,1.1,1.2,2.1,2.2 "$WORK/old.inv" "$WORK/new.inv" > "$WORK/common.modes"

# ---- svn cross-check data ----------------------------------------------------
SVN_OK=0
if test -n "$SVN_BASE"; then
  echo "listing ${SVN_BASE}/branches/${MAJMIN}.x and tags/${OLD_VER} in svn (cross-check) ..." >&2
  if svn ls -R "${SVN_BASE}/branches/${MAJMIN}.x" > "$WORK/svn.branch" 2>/dev/null &&
     svn ls -R "${SVN_BASE}/tags/${OLD_VER}" > "$WORK/svn.oldtag" 2>/dev/null; then
    SVN_OK=1
  else
    echo "svn listing failed, continuing without the cross-checks" >&2
  fi
fi
# docs/manual sources changed on the branch since the old tag was cut, so
# generated pages with content changes can be tied to a commit
: > "$WORK/svn.docs-changes"
if test "$SVN_OK" = 1; then
  tagrev=$(svn log -q --stop-on-copy "${SVN_BASE}/tags/${OLD_VER}" 2>/dev/null | sed -n 's/^r\([0-9]*\) .*/\1/p' | tail -1)
  if test -n "$tagrev"; then
    svn log -q -v -r "${tagrev}:HEAD" "${SVN_BASE}/branches/${MAJMIN}.x/docs/manual" 2>/dev/null |
      perl -ne 'if (/^r(\d+) \|/) { $r = $1 } elsif (m,^   [AMDR] /httpd/httpd/branches/[^/]+/(docs/manual/\S+),) { print "$1 r$r\n" }' |
      sort -u > "$WORK/svn.docs-changes"
  fi
fi
# docs_source_change HTMLPATH -> the revisions in which its docs/manual source changed
docs_source_change() {
  src=$(echo "$1" | sed -e 's/\.html\(\.[^/]*\)\{0,1\}$//')
  grep -E "^${src}\.xml(\.[a-z-]+)? r" "$WORK/svn.docs-changes" | awk '{print $2}' | sort -u | tr '\n' ' '
}
in_svn_branch() { test "$SVN_OK" = 1 && grep -qx -- "$1" "$WORK/svn.branch"; }
in_svn_oldtag() { test "$SVN_OK" = 1 && grep -qx -- "$1" "$WORK/svn.oldtag"; }
svn_prop() {   # PROP PATH
  test "$SVN_OK" = 1 || return 0
  svn propget "$1" "${SVN_BASE}/branches/${MAJMIN}.x/$2" 2>/dev/null
}

# ---- normalizers -------------------------------------------------------------
# svn keyword expansions collapsed to their bare form
norm_keywords() {
  perl -pe 's/\$(Revision|Rev|LastChangedRevision|Date|LastChangedDate|Author|LastChangedBy|Id|Header|HeadURL|URL)(: ?[^\$]*?)? ?\$/\$$1\$/g' "$1"
}
# old/new version strings, years and long dates collapsed
norm_versions() {
  perl -pe "s/\\Q$OLD_VER\\E/VERSION/g; s/\\Q$NEW_VER\\E/VERSION/g; s/\\b(19|20)\\d\\d\\b/YEAR/g; s/\\b(January|February|March|April|May|June|July|August|September|October|November|December) +\\d{1,2}, YEAR/DATE/g" "$1"
}
# the "this translation may be out of date" banner the docs build inserts
norm_outofdate() {
  perl -0pe 's#\s*<div class="outofdate">.*?</div>##sg' "$1"
}
strip_cr() { tr -d '\r' < "$1"; }

# path_category PATH   what kind of file this is, by path
path_category() {
  case "$1" in
    CHANGES|STATUS|NOTICE|LICENSE|README*|ROADMAP|VERSIONING|INSTALL|ABOUT_APACHE|Announcement*|include/ap_release.h|docs/manual/style/version.ent|httpd.spec)
      echo release-metadata ;;
    configure|aclocal.m4|include/ap_config_auto.h.in|build/config.guess|build/config.sub|build/ltmain.sh|build/libtool.m4|build/ltoptions.m4|build/ltsugar.m4|build/ltversion.m4|build/lt~obsolete.m4|build/argz.m4|build/ltcf-*|build/aclocal.m4|modules/*/configure|srclib/*/configure)
      echo autotools-generated ;;
    docs/manual/*.html|docs/manual/*.html.*|docs/manual/*/*.html|docs/manual/*/*.html.*|docs/manual/*/*/*.html|docs/manual/*/*/*.html.*|docs/manual/*/*/*/*.html|docs/manual/*/*/*/*.html.*)
      echo docs-generated ;;
    docs/manual/*)
      echo docs-source ;;
    docs/*)
      echo docs-other ;;
    test/*)
      echo tests ;;
    *.c|*.h|*.cpp|*.y|*.l|*.m4|*.in|*.xml|*.xsl|*.dtd|*.mk|Makefile*|*.py|*.pl|*.sh|*.awk|*.dsp|*.dsw|*.mak|*.vcproj|*.sln|*.def|*.rc|*.ico|*.bmp|*.xpm|*.conf|*.layout|*.types|*.gif|*.png|*.jpg|*.css|*.js|*.pem|*.crt|*.key|*.exp|*.dat|*.map|*.bat|*.txt|CMakeLists.txt|.gitignore|.github/*|build/*|include/*|support/*|srclib/*|os/*|modules/*|server/*|changes-entries/*)
      echo source ;;
    *)
      echo other ;;
  esac
}

# ---- classify common files ---------------------------------------------------
CATS="identical mode-only symlink keyword-expansion eol-only version-string-only docs-outofdate-banner release-metadata autotools-generated docs-generated docs-source docs-other tests source other"
for c in $CATS; do : > "$WORK/cat.$c"; done
while IFS="$TAB" read -r f om ot nm nt; do
  o="$OLD_ROOT/$f"; n="$NEW_ROOT/$f"
  if test "$ot" = l -o "$nt" = l; then
    if test "$ot" != "$nt" -o "`readlink "$o"`" != "`readlink "$n"`"; then
      echo "$f (old: $ot `readlink "$o" 2>/dev/null`, new: $nt `readlink "$n" 2>/dev/null`)" >> "$WORK/cat.symlink"
    fi
    continue
  fi
  modenote=""
  test "$om" = "$nm" || modenote=" (mode old $om, new $nm)"
  if cmp -s "$o" "$n"; then
    if test -n "$modenote"; then
      echo "$f$modenote" >> "$WORK/cat.mode-only"
    else
      echo "$f" >> "$WORK/cat.identical"
    fi
    continue
  fi
  if norm_keywords "$o" | cmp -s - <(norm_keywords "$n"); then
    echo "$f$modenote" >> "$WORK/cat.keyword-expansion"
  elif strip_cr "$o" | cmp -s - <(strip_cr "$n"); then
    echo "$f$modenote" >> "$WORK/cat.eol-only"
  elif norm_versions "$o" | norm_keywords /dev/stdin | cmp -s - <(norm_versions "$n" | norm_keywords /dev/stdin); then
    echo "$f$modenote" >> "$WORK/cat.version-string-only"
  elif norm_outofdate "$o" | norm_versions /dev/stdin | cmp -s - <(norm_outofdate "$n" | norm_versions /dev/stdin); then
    echo "$f$modenote" >> "$WORK/cat.docs-outofdate-banner"
  else
    echo "$f$modenote" >> "$WORK/cat.$(path_category "$f")"
  fi
done < "$WORK/common.modes"

# ---- classify added / removed files with the svn cross-check -----------------
# only in new:  upstream-added (in branch, not in old tag)   expected
#               not-in-svn    (not in branch at all)         scrutiny
#               unchecked     (no svn)                       by path category
# only in old:  upstream-removed (not in branch)             expected
#               missing       (still in branch)              scrutiny
for c in upstream-added not-in-svn unchecked; do : > "$WORK/only.new.$c"; done
while read -r f; do
  if test "$SVN_OK" != 1; then
    echo "$f [$(path_category "$f")]" >> "$WORK/only.new.unchecked"
  elif in_svn_branch "$f" && ! in_svn_oldtag "$f"; then
    echo "$f" >> "$WORK/only.new.upstream-added"
  elif in_svn_branch "$f"; then
    echo "$f (also in svn tags/${OLD_VER}: was it dropped from the old tarball?)" >> "$WORK/only.new.not-in-svn"
  else
    echo "$f" >> "$WORK/only.new.not-in-svn"
  fi
done < "$WORK/only.new"
for c in upstream-removed missing unchecked; do : > "$WORK/only.old.$c"; done
while read -r f; do
  if test "$SVN_OK" != 1; then
    echo "$f [$(path_category "$f")]" >> "$WORK/only.old.unchecked"
  elif in_svn_branch "$f"; then
    echo "$f" >> "$WORK/only.old.missing"
  else
    echo "$f" >> "$WORK/only.old.upstream-removed"
  fi
done < "$WORK/only.old"
: > "$WORK/emptydirs.in-svn"; : > "$WORK/emptydirs.gone-upstream"
while read -r d; do
  if test "$SVN_OK" = 1 && ! in_svn_branch "$d/"; then
    echo "$d" >> "$WORK/emptydirs.gone-upstream"
  else
    echo "$d" >> "$WORK/emptydirs.in-svn"
  fi
done < "$WORK/emptydirs.only.old"

# svn properties behind the keyword and eol findings
annotate_props() {   # FILE PROP
  test "$SVN_OK" = 1 || return 0
  tmp="$1.tmp"; : > "$tmp"
  while read -r line; do
    f="${line%% (*}"
    p=$(svn_prop "$2" "$f")
    echo "$line [svn $2=${p:-unset}]" >> "$tmp"
  done < "$1"
  mv "$tmp" "$1"
}
annotate_props "$WORK/cat.keyword-expansion" svn:keywords
annotate_props "$WORK/cat.eol-only" svn:eol-style

# generated docs with content changes: explained by a source commit or not
: > "$WORK/cat.docs-generated.explained"; : > "$WORK/cat.docs-generated.unexplained"
while read -r line; do
  f="${line%% (*}"
  if test "$SVN_OK" = 1; then
    why=$(docs_source_change "$f")
    if test -n "$why"; then
      echo "$line [source commits: ${why% }]" >> "$WORK/cat.docs-generated.explained"
    else
      echo "$line" >> "$WORK/cat.docs-generated.unexplained"
    fi
  else
    echo "$line" >> "$WORK/cat.docs-generated.unexplained"
  fi
done < "$WORK/cat.docs-generated"

# ---- report ------------------------------------------------------------------
count() { wc -l < "$1" | tr -d ' '; }
show() {   # FILE LABEL
  n=$(count "$1")
  test "$n" -gt 0 || return 0
  echo "  $2 ($n):"
  if test "$VERBOSE" = 1 -o "$n" -le "$LIMIT"; then
    sed -e 's/^/    /' "$1"
  else
    head -n "$LIMIT" "$1" | sed -e 's/^/    /'
    echo "    ... $(( n - LIMIT )) more (use -v)"
  fi
}
showdiff() {
  test "$SHOWDIFF" = 1 || return 0
  while read -r line; do
    f="${line%% (*}"; f="${f%% [*}"
    echo "    --- diff $f"
    diff "$OLD_ROOT/$f" "$NEW_ROOT/$f" | sed -e 's/^/    /' | head -30
  done < "$1"
}
SCRUTINY=0
bump() { SCRUTINY=$(( SCRUTINY + $(count "$1") )); }

cat <<EOT

COMPARING $OLD_TOP (old) with $NEW_TOP (new)
  old: $OLD_SRC
  new: $NEW_SRC
  files: old $(count "$WORK/old.files"), new $(count "$WORK/new.files"), common $(count "$WORK/common"), identical $(count "$WORK/cat.identical")
  tar owners: old $OLD_OWNERS/ new $NEW_OWNERS
  svn cross-check: $(test "$SVN_OK" = 1 && echo "${SVN_BASE}/branches/${MAJMIN}.x and tags/${OLD_VER}" || echo "off")

=== NEEDS SCRUTINY =========================================================
EOT
show "$WORK/only.new.not-in-svn" "only in NEW and not on the svn branch (where did they come from?)"
bump "$WORK/only.new.not-in-svn"
show "$WORK/only.new.unchecked" "only in NEW (no svn cross-check; verify each is a real upstream addition)"
bump "$WORK/only.new.unchecked"
show "$WORK/only.old.missing" "only in OLD but still on the svn branch (LOST by the export)"
bump "$WORK/only.old.missing"
show "$WORK/only.old.unchecked" "only in OLD (no svn cross-check; verify each was really removed upstream)"
bump "$WORK/only.old.unchecked"
show "$WORK/emptydirs.in-svn" "empty directories in OLD and in svn, absent from NEW (git does not track empty directories)"
bump "$WORK/emptydirs.in-svn"
show "$WORK/emptydirs.only.new" "empty directories only in NEW"
bump "$WORK/emptydirs.only.new"
show "$WORK/cat.keyword-expansion" "differ only by svn keyword expansion (\$Revision\$ etc.; a git export leaves them unexpanded)"
showdiff "$WORK/cat.keyword-expansion"
bump "$WORK/cat.keyword-expansion"
show "$WORK/cat.eol-only" "differ only by line endings"
bump "$WORK/cat.eol-only"
show "$WORK/cat.mode-only" "same content, different permissions (svn:executable vs git mode)"
bump "$WORK/cat.mode-only"
show "$WORK/cat.symlink" "symlinks that changed"
bump "$WORK/cat.symlink"
show "$WORK/cat.other" "changed files that fit no expected category"
showdiff "$WORK/cat.other"
bump "$WORK/cat.other"
if test "$SVN_OK" = 1; then
  show "$WORK/cat.docs-generated.unexplained" "generated docs with content changes but no docs/manual source commit since ${OLD_VER} (build tool difference?)"
  showdiff "$WORK/cat.docs-generated.unexplained"
  bump "$WORK/cat.docs-generated.unexplained"
fi
test "$SCRUTINY" -gt 0 || echo "  (nothing)"

cat <<EOT

=== EXPECTED RELEASE-TO-RELEASE ============================================
EOT
show "$WORK/only.new.upstream-added" "only in NEW, added on the svn branch since ${OLD_VER}"
show "$WORK/only.old.upstream-removed" "only in OLD, removed from the svn branch since ${OLD_VER}"
show "$WORK/emptydirs.gone-upstream" "empty directories in OLD that no longer exist upstream"
show "$WORK/cat.release-metadata" "release metadata (CHANGES, ap_release.h, version.ent, httpd.spec, ...)"
show "$WORK/cat.version-string-only" "differ only by version/year/date strings"
show "$WORK/cat.source" "source changes (commits since ${OLD_VER})"
show "$WORK/cat.tests" "test suite changes"
show "$WORK/cat.docs-source" "docs sources"
show "$WORK/cat.docs-other" "other docs"
show "$WORK/cat.docs-outofdate-banner" "generated docs that only gained/lost the 'translation may be out of date' banner"
if test "$SVN_OK" = 1; then
  show "$WORK/cat.docs-generated.explained" "generated docs with content changes, explained by a docs/manual commit since ${OLD_VER}"
else
  show "$WORK/cat.docs-generated" "generated docs with content changes (no svn cross-check; should follow docs commits since ${OLD_VER})"
fi
show "$WORK/cat.autotools-generated" "autotools output (depends on the RM's autoconf/libtool versions)"

echo
if test "$SCRUTINY" -gt 0; then
  echo "RESULT: $SCRUTINY item(s) need scrutiny (see above)."
  echo "extracted trees kept in $WORK (old/, new/)"
  exit 2
else
  echo "RESULT: no differences outside the expected categories."
fi
