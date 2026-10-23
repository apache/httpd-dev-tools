# Wrappers for the svn verbs the scripts use on the dist.apache.org checkout
# (dist/apache.org-dist) and the private pmc checkout (dist/pmc).
#
# DIST_MODE=svn    real svn checkouts, committed after a prompt (default)
# DIST_MODE=local  plain directories, seeded once from a read-only svn export
#                  and kept between steps so each script sees what the
#                  previous one left behind. Nothing is ever committed. A
#                  pristine copy of the seed is kept in
#                  ${DIST_DIR}/${LOCAL_SEED_DIRNAME} so *_stat can still show
#                  what changed. That directory exists only in local mode.
#
# Sourced by common-lib.sh. dist_* and pmc_* behave identically; two names
# are kept so call sites read naturally.

# where DIST_MODE=local keeps the pristine copy of the exported dist/pmc trees
LOCAL_SEED_DIRNAME="local-dist-mode-seed"

dist_mode_is_local() {
  test "${DIST_MODE}" = local
}

dist_validate() {
  case "${DIST_MODE}" in
    svn|local) ;;
    *) fail "DIST_MODE must be 'svn' or 'local', not '${DIST_MODE}'" ;;
  esac
  if test "${DIST_MODE}" = svn -a "${SCM}" = git && git_src_is_fork; then
    if test "${FORCE_DIST_SVN}" != 1; then
      fail "DIST_MODE=svn with a fork (${GIT_SRC_URL}) would publish a rehearsal to dist.apache.org and pmc. Unset DIST_MODE (local is implied for forks) or set FORCE_DIST_SVN=1 if you really mean it."
    fi
    warn "DIST_MODE=svn with fork ${GIT_SRC_URL}: dist.apache.org and pmc WILL be committed to (FORCE_DIST_SVN=1)"
  fi
}

# local_mode_note TEXT   prints TEXT (for prompts) only in local mode
local_mode_note() {
  if dist_mode_is_local; then
    printf '%s' "$1"
  fi
}

dist_banner() {
  if dist_mode_is_local; then
    echo "DIST_MODE=local (${DIST_MODE_ORIGIN}): nothing will be committed to dist.apache.org or pmc"
  fi
}

# the pristine copy of a locally seeded directory
local_seed_path() {
  echo "${DIST_DIR}/${LOCAL_SEED_DIRNAME}/${1#${DIST_DIR}/}"
}

local_seed_save() {
  seed=`local_seed_path "$1"`
  rm -rf "${seed}"
  mkdir -p "`dirname "${seed}"`"
  cp -R "$1" "${seed}"
}

# dist_checkout PATH SUBPATH...
# svn:   sparse checkout of SVN_DIST_URL at PATH with SUBPATHs at depth immediates
# local: export each missing SUBPATH read-only, keep the ones already there
dist_checkout() {
  path="$1"; shift
  test -n "${SVN_DIST_URL}" || fail "SVN_DIST_URL not set"
  if dist_mode_is_local; then
    for sub in "$@"; do
      if test -d "${path}/${sub}"; then
        echo "keeping local ${path}/${sub} (DIST_MODE=local)"
        continue
      fi
      echo "exporting ${SVN_DIST_URL%/}/${sub} to ${path}/${sub} (read only) ..."
      mkdir -p "`dirname "${path}/${sub}"`"
      svn export --depth immediates "${SVN_DIST_URL%/}/${sub}" "${path}/${sub}" >/dev/null
      local_seed_save "${path}/${sub}"
    done
    return 0
  fi
  # SVN repository is huge, carefully check out only what we need
  rm -rf "${path}"
  echo "checking out dist from ${SVN_DIST_URL} ..."
  svn checkout --depth=empty "${SVN_DIST_URL}" "${path}" >/dev/null
  for sub in "$@"; do
    echo "checking out ${path}/${sub} ..."
    svn update --set-depth immediates --parents "${path}/${sub}" >/dev/null
  done
}

# pmc_checkout DEST   checkout (or local export) of SVN_PMC_URL/PROJECT
pmc_checkout() {
  dest="$1"
  test -n "${SVN_PMC_URL}" || fail "SVN_PMC_URL not set"
  if dist_mode_is_local; then
    if test -d "${dest}"; then
      echo "keeping local ${dest} (DIST_MODE=local)"
      return 0
    fi
    echo "exporting pmc/${PROJECT} to ${dest} (read only) ..."
    svn export "${SVN_PMC_URL}/${PROJECT}" "${dest}" >/dev/null
    local_seed_save "${dest}"
    return 0
  fi
  echo "checking out pmc/${PROJECT} as ${dest}"
  rm -rf "${dest}"
  svn checkout "${SVN_PMC_URL}/${PROJECT}" "${dest}" >/dev/null
}

dist_add() {
  if dist_mode_is_local; then
    return 0
  fi
  svn add "$@"
}

# dist_rm [--force] PATH...
dist_rm() {
  if dist_mode_is_local; then
    paths=""
    for p in "$@"; do
      test "$p" = "--force" || paths="$paths $p"
    done
    rm -rf $paths
    return 0
  fi
  svn rm "$@"
}

# dist_mv SRC... DEST
dist_mv() {
  if dist_mode_is_local; then
    mv "$@"
    return 0
  fi
  svn mv "$@"
}

# dist_stat PATH   what changed since checkout/seed
dist_stat() {
  if dist_mode_is_local; then
    seed=`local_seed_path "$1"`
    if test -d "${seed}"; then
      diff -rq "${seed}" "$1" || true
    else
      echo "(no seed found for $1, cannot show changes)"
    fi
    return 0
  fi
  svn stat "$1"
}

# dist_commit MSG PATH
dist_commit() {
  if dist_mode_is_local; then
    echo "local mode: not committing $2 ($1)"
    return 0
  fi
  svn commit -m "$1" "$2"
}

pmc_add()    { dist_add "$@"; }
pmc_rm()     { dist_rm "$@"; }
pmc_mv()     { dist_mv "$@"; }
pmc_stat()   { dist_stat "$@"; }
pmc_commit() { dist_commit "$@"; }
