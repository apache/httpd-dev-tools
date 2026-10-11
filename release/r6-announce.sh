#!/usr/bin/env bash

# Announce a committed release to the world

#Useful for debugging
#set -x

#Bail when non-zero return codes are encountered
set -e

usage () {
    cat <<EOF 1>&2
usage: $0 [options] [version]
  Announce a committed release to the world.
  Arguments:
    version        as 'm.n.p(-suffix)?', the version to use.
  Options:
    -h             print usage information
    -u user-id     your apache user-id, e.g 'ylavic'
EOF
  exit 1
}

asf_id=""

while getopts "hu:y" opt; do
    case $opt in
        h)  usage
            ;;
        u)  asf_id="$OPTARG"
            ;;
        y)  ALWAYS_YES=1
            ;;
    esac
done
shift $((OPTIND-1))

source `dirname $0`/common-lib.sh
source `dirname $0`/env.sh

detect_checkout
detect_version $1

test -n "${asf_id}" || fail "please specify your ASF id as '-u <asf-id>'"

AO_DIST_PATH="dist/apache.org-dist"
AO_DIST_RELEASE_PATH="${AO_DIST_PATH}/release/${PROJECT}"

TAR_BASENAME="${PROJECT}-${VERSION}"
ANNOUNCEMENT="Announcement${v_major}.${v_minor}.txt"
ANNOUNCE_LISTS="announce@apache.org announce@httpd.apache.org"

# SVN repository is huge, carefully check out only what we need
rm -rf "${AO_DIST_PATH}"
echo "checking out dist from ${SVN_DIST_URL} ..."
svn checkout --depth=empty "$SVN_DIST_URL" "${AO_DIST_PATH}" >/dev/null
echo "checking out ${AO_DIST_RELEASE_PATH} ..."
svn update --set-depth immediates --parents "${AO_DIST_RELEASE_PATH}" >/dev/null

if ! ls "${AO_DIST_RELEASE_PATH}/${TAR_BASENAME}".* >/dev/null 2>&1; then
  fail "not found: ${AO_DIST_RELEASE_PATH}/${TAR_BASENAME}.*"
fi
if ! test -f "${AO_DIST_RELEASE_PATH}/CHANGES_${VERSION}"; then
  fail "not found: ${AO_DIST_RELEASE_PATH}/CHANGES_${VERSION}"
fi
if ! test -f "${AO_DIST_RELEASE_PATH}/${ANNOUNCEMENT}"; then
  fail "not found: ${AO_DIST_RELEASE_PATH}/${ANNOUNCEMENT}"
fi

# downloads.apache.org syncs from SVN with some delay, and anything the CDN
# fetches in the meantime (an outdated file or a 404) stays cached for a while.
for changes in "CHANGES_${VERSION}" "CHANGES_${v_major}.${v_minor}"; do
  for base in "https://downloads.apache.org/${PROJECT}" "https://dlcdn.apache.org/${PROJECT}"; do
    echo "verifying ${base}/${changes} ..."
    if ! curl -fsSL "${base}/${changes}" |
         cmp -s - "${AO_DIST_RELEASE_PATH}/${changes}"; then
      fail "${base}/${changes} does not match SVN. Wait (the CDN cache expires within about 30 minutes) or ask ASF Infra to purge it, then rerun $0"
    fi
  done
done

DATE=`date '+%a, %d %b %Y %H:%M:%S %z'`
email="${asf_id}@apache.org"

echo "Announcement Emails are being prepared in ${DIST_DIR}/mail_announce_*."
echo "You may use the following commands to send these:"
echo ""
counter=0
for rcpt in ${ANNOUNCE_LISTS}; do
    MID="<`perl -e 'print time . ".";@chars=("A".."Z",0..0);print $chars[rand @chars] for 1..8;'`@httpd.apache.org>"
    mail_file="${DIST_DIR}/mail_announce_${VERSION}-${counter}.txt"
    cat <<EOF > "$mail_file"
From: ${asf_id} <$email>
To: $rcpt
Reply-To: dev@httpd.apache.org
Subject: [ANNOUNCEMENT] Apache HTTP Server $VERSION Released
Date: $DATE
Message-ID: $MID

EOF
  cat "${AO_DIST_RELEASE_PATH}/${ANNOUNCEMENT}" >> "${mail_file}"
  cat <<EOF
  curl --url 'smtps://mail-relay.apache.org:465' \\
    --ssl-reqd --mail-from "${email}" \\
    --mail-rcpt "${rcpt}"  --user '${asf_id}' \\
    --upload-file '${mail_file}'

EOF
  printf "\n\n--\nTo unsubscribe from this announcement list, send a mail to\n<%s> from your subscribed address.\n" \
          ${rcpt/announce/announce-unsubscribe} >> "$mail_file"
  counter=`expr $counter + 1`
done


CVES_MENTIONED=`fgrep CVE- dist/apache.org-dist/release/httpd/CHANGES_${VERSION}`
if test -n "${CVES_MENTIONED}"; then
  CVE_COUNT=`echo "${CVES_MENTIONED}" | grep -oE 'CVE-[0-9]+-[0-9]+' | sort -u | wc -l | tr -d ' '`
  cat << EOF
Then set the following CVEs mentioned to READY on the ASF cveprocess site (and send the emails from the OSS/ASF tab):
${CVES_MENTIONED}
Total CVEs: ${CVE_COUNT}
EOF
else
  echo "There seem to be no CVEs mentioned in the CHANGES_${VERSION} file."
fi
echo "You are done. Open the champagne!"
