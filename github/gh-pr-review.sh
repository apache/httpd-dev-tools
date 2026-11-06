#!/bin/bash
#
# Review open pull requests against apache/httpd, tallying backport votes.
#
# Backport policy: a PR needs three votes, where each of the following
# counts as one vote:
#   - the PR author is an httpd committer
#   - each approving review from an httpd committer (other than the author)
#   - CI passes
#
# A GitHub user is treated as a committer if they have write (or higher)
# permission on the repository, which ASF gitbox grants to committers who
# have linked their GitHub account.
#
# With no PR numbers, lists all open PRs against the base branch (2.4.x
# by default) with their vote tally.  With PR numbers, shows a detailed
# vote breakdown for each.  Output is ANSI-coloured on a terminal; use -j
# for machine-readable JSON instead.
#
# Requires gh (authenticated via "gh auth login") and jq.

set -euo pipefail

REPO="apache/httpd"
BASE="2.4.x"
DRAFTS=0
READY_ONLY=0
SKIP_CONFLICTS=0
CI_ONLY=0
JSON=0
VOTES_NEEDED=3

# Colours and OSC 8 hyperlinks (disabled if stdout is not a terminal)
if [ -t 1 ]; then
    LINKS=1
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
    RESET=$'\033[0m'
else
    LINKS=0
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" RESET=""
fi

# link <url> <text>: print text as a terminal hyperlink to url.
link() {
    if [ "$LINKS" -eq 1 ] && [ -n "$1" ]; then
        printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"
    else
        printf '%s' "$2"
    fi
}

usage() {
    echo "Usage: $0 [-b branch] [-a] [-d] [-u] [-c] [-j] [PR-number...]" >&2
    echo "  -b branch   base branch to list PRs for (default $BASE)" >&2
    echo "  -a          only list approved PRs (enough votes to merge)" >&2
    echo "  -d          include draft PRs" >&2
    echo "  -u          ignore PRs with merge conflicts" >&2
    echo "  -c          only list PRs where CI passes" >&2
    echo "  -j          machine-readable JSON output (array of PR objects)" >&2
    echo "  PR-number   show a detailed vote breakdown for the given PR(s)" >&2
    exit 1
}

# jq definition normalising a statusCheckRollup entry (either a CheckRun
# or a StatusContext) to SUCCESS, FAILURE or PENDING.
JQ_CHECK='def check_state:
    (if .__typename == "CheckRun" then
        (if .status == "COMPLETED" then .conclusion else "PENDING" end)
     else .state end) as $s
    | if ($s == "SUCCESS" or $s == "NEUTRAL" or $s == "SKIPPED") then "SUCCESS"
      elif ($s == "PENDING" or $s == "EXPECTED" or $s == "" or $s == null) then "PENDING"
      else "FAILURE" end;
def ci_state:
    [.statusCheckRollup[]? | check_state] as $c
    | if ($c | length) == 0 then "none"
      elif ($c | index("FAILURE")) then "fail"
      elif ($c | index("PENDING")) then "pending"
      else "pass" end;'

PR_FIELDS="number,title,url,author,isDraft,latestReviews,statusCheckRollup,mergeable"

declare -A COMMITTER_CACHE=()

# is_committer <login>: succeeds if login has write access to the repo.
is_committer() {
    local login="$1" perm
    if [ -z "${COMMITTER_CACHE[$login]+set}" ]; then
        perm=$(gh api "repos/$REPO/collaborators/$login/permission" \
                  --jq .permission 2>/dev/null || echo none)
        case "$perm" in
            admin|maintain|write) COMMITTER_CACHE[$login]=1 ;;
            *)                    COMMITTER_CACHE[$login]=0 ;;
        esac
    fi
    [ "${COMMITTER_CACHE[$login]}" = 1 ]
}

# Globals set by tally(): T_AUTHOR T_APPROVERS T_CHANGES T_CI T_VOTES
#
# tally <pr-json>
tally() {
    local json="$1" author login
    author=$(jq -r '.author.login' <<<"$json")

    T_AUTHOR=0
    if is_committer "$author"; then T_AUTHOR=1; fi

    T_APPROVERS=()
    T_CHANGES=()
    while IFS=$'\t' read -r login state; do
        [ -n "$login" ] || continue
        [ "$login" != "$author" ] || continue
        is_committer "$login" || continue
        case "$state" in
            APPROVED)          T_APPROVERS+=("$login") ;;
            CHANGES_REQUESTED) T_CHANGES+=("$login") ;;
        esac
    done < <(jq -r '.latestReviews[]? | [.author.login, .state] | @tsv' <<<"$json" | sort -u)

    T_CI=$(jq -r "$JQ_CHECK ci_state" <<<"$json")

    T_VOTES=$((T_AUTHOR + ${#T_APPROVERS[@]}))
    if [ "$T_CI" = pass ]; then T_VOTES=$((T_VOTES + 1)); fi
}

# pr_record <pr-json>: print a JSON object summarising the tally done by
# a preceding tally() call on the same PR.
pr_record() {
    jq -c --argjson author_committer "$([ "$T_AUTHOR" -eq 1 ] && echo true || echo false)" \
          --arg ci "$T_CI" --argjson votes "$T_VOTES" --argjson needed "$VOTES_NEEDED" \
          --args '{number, title, url, author: .author.login, draft: .isDraft,
                   author_committer: $author_committer,
                   approvers: ($ARGS.positional | map(select(startswith("A:")) | .[2:])),
                   changes_requested: ($ARGS.positional | map(select(startswith("C:")) | .[2:])),
                   conflicts: (.mergeable == "CONFLICTING"),
                   ci: $ci, votes: $votes, ready: ($votes >= $needed)}' \
          ${T_APPROVERS[@]+"${T_APPROVERS[@]/#/A:}"} \
          ${T_CHANGES[@]+"${T_CHANGES[@]/#/C:}"} <<<"$1"
}

# mergeable <pr-json>: print MERGEABLE, CONFLICTING or UNKNOWN.  GitHub
# computes mergeability lazily, so "gh pr list" often reports UNKNOWN;
# a direct query of the PR usually resolves it.
mergeable() {
    local m number
    m=$(jq -r '.mergeable // "UNKNOWN"' <<<"$1")
    if [ "$m" = UNKNOWN ]; then
        number=$(jq -r .number <<<"$1")
        m=$(gh pr view "$number" -R "$REPO" --json mergeable --jq .mergeable \
                2>/dev/null || echo UNKNOWN)
    fi
    echo "$m"
}

merge_label() {
    case "$1" in
        CONFLICTING) echo conflict ;;
        MERGEABLE)   echo clean ;;
        *)           echo unknown ;;
    esac
}

merge_colour() {
    case "$1" in
        CONFLICTING) echo "$RED" ;;
        MERGEABLE)   echo "$GREEN" ;;
        *)           echo "$DIM" ;;
    esac
}

votes_colour() {
    if [ "$1" -ge "$VOTES_NEEDED" ]; then echo "$GREEN"
    elif [ "$1" -gt 0 ]; then echo "$YELLOW"
    else echo "$DIM"; fi
}

ci_colour() {
    case "$1" in
        pass)    echo "$GREEN" ;;
        fail)    echo "$RED" ;;
        pending) echo "$YELLOW" ;;
        *)       echo "$DIM" ;;
    esac
}

list_prs() {
    local prs lines=() json number title url author draft ready cr flag merge line

    prs=$(gh pr list -R "$REPO" --base "$BASE" --state open --limit 500 \
             --json "$PR_FIELDS")

    while IFS= read -r json; do
        number=$(jq -r .number <<<"$json")
        title=$(jq -r .title <<<"$json")
        url=$(jq -r .url <<<"$json")
        author=$(jq -r .author.login <<<"$json")
        draft=$(jq -r .isDraft <<<"$json")
        [ "$draft" = false ] || [ "$DRAFTS" -eq 1 ] || continue

        tally "$json"
        json=$(jq -c --arg m "$(mergeable "$json")" '.mergeable = $m' <<<"$json")
        [ "$READY_ONLY" -eq 0 ] || [ "$T_VOTES" -ge "$VOTES_NEEDED" ] || continue
        [ "$SKIP_CONFLICTS" -eq 0 ] \
            || [ "$(jq -r .mergeable <<<"$json")" != CONFLICTING ] || continue
        [ "$CI_ONLY" -eq 0 ] || [ "$T_CI" = pass ] || continue

        if [ "$JSON" -eq 1 ]; then
            lines+=("$(pr_record "$json")")
            continue
        fi

        ready="     "
        [ "$T_VOTES" -lt "$VOTES_NEEDED" ] || ready="READY"
        cr=""
        [ ${#T_CHANGES[@]} -eq 0 ] || cr=" ${RED}[changes requested]${RESET}"
        flag=""
        [ "$draft" = false ] || flag=" ${DIM}[draft]${RESET}"
        merge=$(jq -r .mergeable <<<"$json")

        line=$(printf '%s%5s%s  %s%d/%d %s%s  A%s R:%d %sCI:%-7s%s  %s%-8s%s  %-14s %s%s%s' \
            "$BOLD" "#$number" "$RESET" \
            "$(votes_colour "$T_VOTES")" "$T_VOTES" "$VOTES_NEEDED" "$ready" "$RESET" \
            "$([ "$T_AUTHOR" -eq 1 ] && echo + || echo -)" "${#T_APPROVERS[@]}" \
            "$(ci_colour "$T_CI")" "$T_CI" "$RESET" \
            "$(merge_colour "$merge")" "$(merge_label "$merge")" "$RESET" \
            "$author" "$(link "$url" "$title")" "$cr" "$flag")
        # Prefix with sort keys: votes descending, then PR number.
        lines+=("$T_VOTES"$'\t'"$number"$'\t'"$line")
    done < <(jq -c '.[]' <<<"$prs")

    if [ "$JSON" -eq 1 ]; then
        printf '%s\n' ${lines[@]+"${lines[@]}"} \
            | jq -s 'sort_by(-.votes, .number)'
        return
    fi

    if [ ${#lines[@]} -eq 0 ]; then
        if [ "$READY_ONLY" -eq 1 ]; then
            echo "No open PRs against $BASE with $VOTES_NEEDED votes."
        else
            echo "No open PRs against $BASE."
        fi
        return
    fi

    echo "${BOLD}Open PRs against ${CYAN}$BASE${RESET}${BOLD} in $REPO${RESET}" \
         "${DIM}(A: author is committer, R: committer approvals)${RESET}"
    echo "${DIM}   PR  Votes      A  R   CI          Merge     Author         Title${RESET}"
    printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1nr -k2,2n | cut -f3-
}

show_pr() {
    local pr="$1" json author title url base login

    json=$(gh pr view "$pr" -R "$REPO" --json "$PR_FIELDS,baseRefName,state")
    title=$(jq -r .title <<<"$json")
    url=$(jq -r .url <<<"$json")
    author=$(jq -r .author.login <<<"$json")
    base=$(jq -r .baseRefName <<<"$json")

    tally "$json"
    json=$(jq -c --arg m "$(mergeable "$json")" '.mergeable = $m' <<<"$json")

    if [ "$JSON" -eq 1 ]; then
        pr_record "$json"
        return
    fi

    echo "${BOLD}${CYAN}#$pr${RESET}${BOLD} $(link "$url" "$title")${RESET}"
    echo "  $url"
    echo "  base: $base, state: $(jq -r .state <<<"$json")$( \
         [ "$(jq -r .isDraft <<<"$json")" = false ] || echo ", ${DIM}draft${RESET}")"
    echo

    if [ "$T_AUTHOR" -eq 1 ]; then
        echo "  ${GREEN}+1${RESET} author $author (committer)"
    else
        echo "  ${DIM} 0 author $author (not a committer)${RESET}"
    fi

    for login in ${T_APPROVERS[@]+"${T_APPROVERS[@]}"}; do
        echo "  ${GREEN}+1${RESET} approved by $login"
    done

    # Reviews which do not count as votes, for information.
    while IFS=$'\t' read -r login state; do
        [ -n "$login" ] || continue
        if [ "$login" = "$author" ]; then
            continue
        elif ! is_committer "$login"; then
            echo "  ${DIM} 0 $state by $login (not a committer)${RESET}"
        elif [ "$state" = CHANGES_REQUESTED ]; then
            echo "  ${RED}!! changes requested by $login${RESET}"
        elif [ "$state" != APPROVED ]; then
            echo "  ${DIM} 0 $state by $login${RESET}"
        fi
    done < <(jq -r '.latestReviews[]? | [.author.login, .state] | @tsv' <<<"$json" | sort -u)

    case "$T_CI" in
        pass) echo "  ${GREEN}+1${RESET} CI passed" ;;
        *)    echo "  $(ci_colour "$T_CI") 0 CI $T_CI${RESET}" ;;
    esac
    if [ "$T_CI" = fail ] || [ "$T_CI" = pending ]; then
        # List failed checks (linked to their logs); summarise pending ones.
        local npending=0 state name curl
        while IFS=$'\t' read -r state name curl; do
            if [ "$state" = FAILURE ]; then
                echo "       ${RED}failed:${RESET} $(link "$curl" "$name")"
            else
                npending=$((npending + 1))
            fi
        done < <(jq -r "$JQ_CHECK"' .statusCheckRollup[] | select(check_state != "SUCCESS")
                   | [check_state, (.name // .context), (.detailsUrl // .targetUrl // "")]
                   | @tsv' <<<"$json" | sort -u)
        [ "$npending" -eq 0 ] || \
            echo "       ${YELLOW}pending:${RESET} $npending check(s) $(link "$url/checks" "(details)")"
    fi

    echo
    echo "  ${BOLD}Votes: $(votes_colour "$T_VOTES")$T_VOTES/$VOTES_NEEDED${RESET}$( \
         [ "$T_VOTES" -lt "$VOTES_NEEDED" ] || echo " ${GREEN}${BOLD}READY${RESET}")$( \
         [ ${#T_CHANGES[@]} -eq 0 ] || echo " ${RED}(changes requested)${RESET}")"

    local merge
    merge=$(jq -r .mergeable <<<"$json")
    case "$merge" in
        CONFLICTING) echo "  ${BOLD}Merge:${RESET} ${RED}conflicts with $base${RESET}" ;;
        MERGEABLE)   echo "  ${BOLD}Merge:${RESET} ${GREEN}clean${RESET}" ;;
        *)           echo "  ${BOLD}Merge:${RESET} ${DIM}unknown${RESET}" ;;
    esac
    echo
}

while getopts "haducjb:" opt; do
    case "$opt" in
        c) CI_ONLY=1 ;;
        u) SKIP_CONFLICTS=1 ;;
        a) READY_ONLY=1 ;;
        d) DRAFTS=1 ;;
        j) JSON=1 ;;
        b) BASE="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

for pr in "$@"; do
    if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
        echo "${RED}Error: PR number must be numeric: $pr${RESET}" >&2
        exit 1
    fi
done

if [ $# -eq 0 ]; then
    list_prs
elif [ "$JSON" -eq 1 ]; then
    for pr in "$@"; do
        show_pr "$pr"
    done | jq -s .
else
    for pr in "$@"; do
        show_pr "$pr"
    done
fi
