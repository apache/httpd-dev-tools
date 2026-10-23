#!/usr/bin/env bash

# Check which CVEs are ready for a release right now.
#

#Useful for debugging
#set -x

#Bail when non-zero return codes are encountered
set -e


usage () {
    cat <<EOF 1>&2
usage: $0 [options]
  Check which CVEs are ready for release.
  Options:
    -h             print usage information
EOF
  exit 1
}

while getopts "h" opt; do
    case $opt in
        h)  usage
            ;;
    esac
done
shift $((OPTIND-1))

source `dirname $0`/common-lib.sh
source `dirname $0`/env.sh

detect_checkout
detect_version ""

calc_ready_CVE_DIRS "${DIST_DIR}/pmc-check"
echo
if test -n "${CVE_DIRS}"; then
  echo "CVEs ready for release:"
  echo "-----------------------"
  for CVE in $CVE_DIRS; do
    echo "$CVE"
    cat "${DIST_DIR}/pmc-check/SECURITY/${CVE}/CHANGES"
  done
  echo "-----------------------"
else
  echo "No CVEs ready for release."
fi