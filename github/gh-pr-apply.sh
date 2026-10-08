#!/bin/bash
set -euo pipefail

REPO="apache/httpd"
GITHUB_URL="https://github.com/$REPO"
CLOG="clog"
current_user=$(git config user.name 2>/dev/null || true)

# Colours (disabled if stdout is not a terminal)
if [ -t 1 ]; then
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
    RESET=$'\033[0m'
else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" RESET=""
fi

PROMPT="${BOLD}${CYAN}[c]${RESET}ommit ${BOLD}${CYAN}[e]${RESET}dit ${BOLD}${CYAN}[g]${RESET}enerate ${BOLD}${CYAN}[p]${RESET}rompt ${BOLD}${CYAN}[v]${RESET}alidate ${BOLD}${CYAN}[t]${RESET}est ${BOLD}${CYAN}[s]${RESET}kip ${BOLD}${CYAN}[r]${RESET}evert ${BOLD}${RED}[a]${RESET}bort${BOLD}${CYAN} > ${RESET}"

usage() {
    echo "Usage: $0 [--squash] <PR-number> [commit-URL]" >&2
    echo "  --squash    apply the whole PR as a single change (the commit" >&2
    echo "              messages are combined into the proposed message)" >&2
    echo "  commit-URL  apply only the given commit from the PR" >&2
    exit 1
}

write_clog() {
    local msg_text="$1"
    local trimmed last
    trimmed=$(printf '%s' "$msg_text" | sed -e :a -e '/^\n*$/{$d;N;ba;}')
    last=$(printf '%s' "$trimmed" | tail -1)
    {
        echo "$trimmed"
        if ! echo "$last" | grep -qE '^[A-Za-z-]+:'; then
            echo
        fi
        if [ -z "$current_user" ] || [ "$author_name" != "$current_user" ]; then
            echo "Submitted by: $author"
        fi
        if [ -z "$ONLY_SHA" ] && [ "$i" -eq "$total" ]; then
            echo "GitHub: closes #$PR"
        else
            echo "GitHub: PR #$PR"
        fi
    } > "$CLOG"
}

# Refuse to commit while any empty APLOGNO() remains in the sources.
check_aplogno() {
    local hits
    hits=$(find server modules os -name \*.c -print0 | xargs -0 grep 'APLOGNO()' || true)
    if [ -n "$hits" ]; then
        echo "${RED}Error: empty APLOGNO() found, assign log tag numbers first:${RESET}" >&2
        echo "$hits" >&2
        return 1
    fi
}

generate_msg() {
    local extra="${1:-}"
    local prompt="Write a GNU ChangeLog-style commit message for this diff. \
The first line should be a short summary. Then list changed files \
with (function): description. Use two-space indentation for \
follow-on lines. Output ONLY the commit message, nothing else."
    if [ -n "$extra" ]; then
        prompt="$prompt Additional instructions: $extra"
    fi
    echo "${DIM}Generating commit message with Claude...${RESET}"
    local claude_msg
    claude_msg=$(svn diff | claude --print "$prompt")
    if [ -n "$claude_msg" ]; then
        write_clog "$claude_msg"
    fi
    echo
    echo "${DIM}--- generated commit message ---${RESET}"
    cat "$CLOG"
    echo "${DIM}--- end ---${RESET}"
    echo
}

# process_patch <api-endpoint> <patch|diff> <commit-message>
#
# Fetch the patch via gh api, apply it to the working copy, check it
# builds, then run the interactive commit loop.  Returns 0 when the
# patch has been committed, skipped or reverted; exits on abort.
# Relies on the globals author, author_name, i, total, PR and
# ONLY_SHA for write_clog.
process_patch() {
    local endpoint="$1" media="$2" msg="$3"
    local patch_file apply_args new_files ans

    patch_file=$(mktemp /tmp/gh-pr-patch.XXXXXX)
    trap "rm -f '$patch_file'" EXIT
    gh api "$endpoint" -H "Accept: application/vnd.github.v3.$media" \
       > "$patch_file"

    if [ ! -s "$patch_file" ]; then
        echo "${RED}Error: empty patch fetched from $endpoint${RESET}" >&2
        rm -f "$patch_file"
        exit 1
    fi

    # Apply the patch
    apply_args=""
    if git apply --check -R "$patch_file" 2>/dev/null; then
        echo "${YELLOW}Patch appears to be already applied.${RESET}"
        read -rp "${BOLD}${CYAN}Skip / Abort? [s/a] > ${RESET}" ans
        case "$ans" in
            s|S) echo "Skipping."; rm -f "$patch_file"; echo; return 0 ;;
            *)   echo "Aborting."; rm -f "$patch_file"; exit 1 ;;
        esac
    elif ! git apply --check "$patch_file" 2>/dev/null; then
        echo "${YELLOW}Warning: patch does not apply cleanly.${RESET}"
        read -rp "${BOLD}${CYAN}Try with fuzz / Skip / Abort? [f/s/a] > ${RESET}" ans
        case "$ans" in
            f|F) apply_args="--recount -C1" ;;
            s|S) echo "Skipping."; rm -f "$patch_file"; echo; return 0 ;;
            *)   echo "Aborting."; rm -f "$patch_file"; exit 1 ;;
        esac
    fi

    # Find new files in the patch (--- /dev/null means a new file)
    new_files=$(awk '/^--- \/dev\/null/{getline; if (/^\+\+\+ b\//) print substr($0,7)}' "$patch_file")

    git apply $apply_args "$patch_file"
    rm -f "$patch_file"

    # svn add only files newly created by this patch
    if [ -n "$new_files" ]; then
        echo "$new_files" | while IFS= read -r f; do
            echo "${GREEN}Adding new file: $f${RESET}"
            svn add --parents "$f"
        done
    fi

    # Check for compile errors
    if ! make -sj8 >/dev/null; then
        echo "${RED}Warning: build failed after applying this patch.${RESET}"
        read -rp "${BOLD}${CYAN}Continue anyway? [y/N] > ${RESET}" ans
        case "$ans" in
            y|Y) ;;
            *)   echo "Aborting."; exit 1 ;;
        esac
    fi

    write_clog "$msg"

    echo
    echo "${DIM}--- svn diff ---${RESET}"
    svn diff
    echo "${DIM}--- end svn diff ---${RESET}"
    echo
    echo "${DIM}--- proposed commit message ---${RESET}"
    cat "$CLOG"
    echo "${DIM}--- end ---${RESET}"
    echo

    read -rp "$PROMPT" ans
    while true; do
        case "$ans" in
            c|C)
                if ! check_aplogno; then
                    read -rp "$PROMPT" ans
                    continue
                fi
                svn commit -F "$CLOG"
                echo "${GREEN}Committed.${RESET}"
                break
                ;;
            e|E)
                ${EDITOR:-vi} "$CLOG"
                echo
                echo "${DIM}--- updated commit message ---${RESET}"
                cat "$CLOG"
                echo "${DIM}--- end ---${RESET}"
                echo
                read -rp "$PROMPT" ans
                ;;
            g|G)
                generate_msg
                read -rp "$PROMPT" ans
                ;;
            p|P)
                read -rp "${BOLD}Additional instructions for Claude:${RESET} " extra_prompt
                generate_msg "$extra_prompt"
                read -rp "$PROMPT" ans
                ;;
            v|V)
                echo "${DIM}Validating diff with Claude...${RESET}"
                svn diff | claude --print \
                    "Review this diff for correctness, security, and style issues. \
Flag any bugs, potential crashes, memory safety problems, or logic errors. \
Be concise. If the change looks correct, say so briefly."
                echo
                read -rp "$PROMPT" ans
                ;;
            t|T)
                echo "${DIM}Running tests...${RESET}"
                make check-test-framework || echo "${YELLOW}Warning: tests failed.${RESET}"
                echo
                read -rp "$PROMPT" ans
                ;;
            s|S)
                echo "Skipping commit (changes remain in working copy)."
                break
                ;;
            r|R)
                echo "${YELLOW}Reverting working copy...${RESET}"
                svn revert -R .
                break
                ;;
            a|A)
                echo "${RED}Aborting, reverting working copy...${RESET}"
                svn revert -R .
                exit 1
                ;;
            *)
                read -rp "Invalid choice. $PROMPT" ans
                ;;
        esac
    done

    echo
    return 0
}

SQUASH=0
args=()
for arg in "$@"; do
    case "$arg" in
        --squash)  SQUASH=1 ;;
        -h|--help) usage ;;
        -*)        echo "${RED}Error: unknown option: $arg${RESET}" >&2; usage ;;
        *)         args+=("$arg") ;;
    esac
done
set -- ${args[@]+"${args[@]}"}

[ $# -ge 1 ] && [ $# -le 2 ] || usage

PR="$1"
ONLY_SHA=""
if [ $# -eq 2 ]; then
    if [ "$SQUASH" -eq 1 ]; then
        echo "${RED}Error: --squash cannot be combined with a commit URL.${RESET}" >&2
        exit 1
    fi
    if [[ "$2" =~ /([0-9a-f]+)$ ]]; then
        ONLY_SHA="${BASH_REMATCH[1]}"
    else
        echo "${RED}Error: cannot extract commit hash from URL: $2${RESET}" >&2
        exit 1
    fi
fi

if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
    echo "${RED}Error: PR number must be numeric.${RESET}" >&2
    exit 1
fi

if svn_st=$(svn st | grep -v '^?') && [ -n "$svn_st" ]; then
    echo "${RED}Error: working copy has uncommitted changes:${RESET}" >&2
    echo "$svn_st" >&2
    exit 1
fi

echo "${BOLD}Fetching commits for ${CYAN}$GITHUB_URL/pull/$PR${RESET}${BOLD} ...${RESET}"

commits=$(gh api --paginate "repos/$REPO/pulls/$PR/commits" --jq '.[].sha')
if [ -z "$commits" ]; then
    echo "${RED}Error: no commits found for PR #$PR${RESET}" >&2
    exit 1
fi

total=$(echo "$commits" | wc -l)
echo "Found ${BOLD}$total${RESET} commit(s)."
echo

if [ "$SQUASH" -eq 1 ]; then
    # Squash mode: apply the PR's combined diff as one change, using the
    # concatenated commit messages (blank-line separated) as the proposed
    # commit message.
    msg=$(gh api --paginate "repos/$REPO/pulls/$PR/commits" \
        --jq '.[].commit.message + "\n"' | tr -d '\r')

    # Credit every distinct commit author in the PR.
    authors=$(gh api --paginate "repos/$REPO/pulls/$PR/commits" \
        --jq '.[].commit.author | "\(.name) <\(.email | sub("@"; " "))>"' | sort -u)
    if [ "$(echo "$authors" | wc -l)" -eq 1 ]; then
        author="$authors"
        author_name="${authors%% <*}"
    else
        author=$(echo "$authors" | paste -sd '|' - | sed 's/|/, /g')
        author_name=""
    fi

    ncommits=$total
    i=1
    total=1

    echo "${BOLD}${GREEN}=== Squashing $ncommits commit(s) from PR #$PR ===${RESET}"
    echo "$msg"
    echo "${DIM}Submitted by: $author${RESET}"
    echo

    process_patch "/repos/$REPO/pulls/$PR" diff "$msg"

    echo "${BOLD}${GREEN}Done.${RESET} Squashed $ncommits commit(s) from PR #$PR."
    exit 0
fi

i=0
for sha in $commits; do
    i=$((i + 1))
    short="${sha:0:12}"

    if [ -n "$ONLY_SHA" ] && [[ "$sha" != "$ONLY_SHA"* ]]; then
        echo "${DIM}Skipping commit $i/$total: $short (not selected)${RESET}"
        continue
    fi

    msg=$(gh api "repos/$REPO/commits/$sha" --jq '.commit.message')
    author_name=$(gh api "repos/$REPO/commits/$sha" --jq '.commit.author.name')
    author_email=$(gh api "repos/$REPO/commits/$sha" --jq '.commit.author.email')
    author="$author_name <${author_email/@/ }>"

    echo "${BOLD}${GREEN}=== Commit $i/$total: $short ===${RESET}"
    echo "$msg"
    echo "${DIM}Submitted by: $author${RESET}"
    echo

    process_patch "/repos/$REPO/commits/$sha" patch "$msg"
done

echo "${BOLD}${GREEN}Done.${RESET} Processed $total commit(s) from PR #$PR."
