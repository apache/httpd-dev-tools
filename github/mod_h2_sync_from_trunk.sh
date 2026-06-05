#!/bin/bash
# Sync SVN revisions from httpd trunk modules/http2 into this git repo.
# Creates a branch, applies each revision as a separate commit, pushes,
# and opens a PR.

set -euo pipefail

SVN_BASE_URL="https://svn.apache.org/repos/asf/httpd/httpd/trunk"
SVN_SUBDIR="modules/http2"
GIT_SUBDIR="mod_http2"
FORK_REMOTE="fork"
UPSTREAM_REPO="icing/mod_h2"

usage() {
    echo "Usage: $0 <svn-revision>..." >&2
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

REVS=()
for REV in "$@"; do
    if ! [[ "$REV" =~ ^[0-9]+$ ]]; then
        echo "Error: revision must be a number: $REV" >&2
        usage
    fi
    REVS+=("$REV")
done

patchfile=$(mktemp)
trap 'rm -f "$patchfile"' EXIT

BRANCH="svn-r$(IFS=-; echo "${REVS[*]}")"
ORIG_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse HEAD)

git fetch origin master
git checkout -b "$BRANCH" origin/master

for REV in "${REVS[@]}"; do
    # Fetch the SVN log message and author
    svn_log=$(svn log -r "$REV" "$SVN_BASE_URL/" 2>&1)
    if ! echo "$svn_log" | grep -q "^r${REV} "; then
        echo "Error: could not fetch SVN log for r${REV}" >&2
        echo "$svn_log" >&2
        git checkout "$ORIG_BRANCH"
        git branch -D "$BRANCH"
        exit 1
    fi

    svn_author=$(echo "$svn_log" | sed -n '2s/^r[0-9]* | \([^ ]*\) |.*/\1/p')
    svn_message=$(echo "$svn_log" | sed '1,3d; /^-\{72\}$/d' | sed -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba}')

    echo "Merging r${REV} by ${svn_author}:"
    echo "$svn_message"
    echo

    # Fetch the diff, filter to modules/http2
    svn diff -c "$REV" "$SVN_BASE_URL/" \
        | filterdiff --strip=2 --addprefix="${GIT_SUBDIR}/" -i "${SVN_SUBDIR}/*" \
        > "$patchfile"

    if [ ! -s "$patchfile" ]; then
        echo "Error: no changes under ${SVN_SUBDIR}/ in r${REV}" >&2
        git checkout "$ORIG_BRANCH"
        git branch -D "$BRANCH"
        exit 1
    fi

    git apply -p0 "$patchfile"

    git add "$GIT_SUBDIR"/

    commit_message="Merge r${REV} from httpd trunk:

${svn_message}

Reference: https://svn.apache.org/viewvc/?view=revision&revision=${REV}"

    git commit -m "$commit_message"
done

git checkout "$ORIG_BRANCH"

git push "$FORK_REMOTE" "${BRANCH}:${BRANCH}"

# Build PR title and body
if [ ${#REVS[@]} -eq 1 ]; then
    pr_title="Backport SVN r${REVS[0]}: $(echo "$svn_message" | head -1)"
    pr_body="Backport of [SVN r${REVS[0]}](https://svn.apache.org/viewvc?view=revision&revision=${REVS[0]}) by \`${svn_author}\`."
else
    pr_title="Backport SVN $(printf 'r%s ' "${REVS[@]}" | sed 's/ $//')"
    pr_body=""
    for REV in "${REVS[@]}"; do
        pr_body="${pr_body}- [SVN r${REV}](https://svn.apache.org/viewvc?view=revision&revision=${REV})
"
    done
fi

if ! gh pr create \
    --repo "$UPSTREAM_REPO" \
    --head "${FORK_REMOTE}:${BRANCH}" \
    --base master \
    --title "$pr_title" \
    --body "$pr_body"; then
    echo "gh pr create failed. Create the PR manually:" >&2
    echo "  https://github.com/${UPSTREAM_REPO}/compare/master...${FORK_REMOTE}:${BRANCH}?expand=1" >&2
    exit 1
fi

echo "Done."
