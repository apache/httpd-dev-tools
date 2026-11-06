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

AO_DIST_PATH="${DIST_DIR}/apache.org-dist"
AO_DIST_RELEASE_PATH="${AO_DIST_PATH}/release/${PROJECT}"

TAR_BASENAME="${PROJECT}-${VERSION}"
ANNOUNCEMENT="Announcement${v_major}.${v_minor}.txt"
ANNOUNCE_LISTS="announce@apache.org announce@httpd.apache.org"

dist_checkout "${AO_DIST_PATH}" "release/${PROJECT}"

if ! ls "${AO_DIST_RELEASE_PATH}/${TAR_BASENAME}".* >/dev/null 2>&1; then
  fail "not found: ${AO_DIST_RELEASE_PATH}/${TAR_BASENAME}.*"
fi
if ! test -f "${AO_DIST_RELEASE_PATH}/CHANGES_${VERSION}"; then
  fail "not found: ${AO_DIST_RELEASE_PATH}/CHANGES_${VERSION}"
fi
if ! test -f "${AO_DIST_RELEASE_PATH}/${ANNOUNCEMENT}"; then
  fail "not found: ${AO_DIST_RELEASE_PATH}/${ANNOUNCEMENT}"
fi

# sync_timing FILE   reports when FILE was last committed to the dist
# repository and how long ago that was, to help judge how much longer the
# sync to downloads.apache.org/dlcdn may take.
sync_timing() {
  committed=`svn info --show-item last-changed-date "$1" 2>/dev/null`
  rev=`svn info --show-item last-changed-revision "$1" 2>/dev/null`
  if test -z "${committed}"; then
    echo "could not determine when `basename "$1"` was committed to the dist repository" >&2
    return 0
  fi
  perl -MTime::Local -MPOSIX=strftime -e '
    my ($name, $rev, $committed) = @ARGV;
    my ($y, $mo, $d, $h, $mi, $s) = $committed =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/
      or die "unexpected svn date: $committed\n";
    my $then = timegm($s, $mi, $h, $d, $mo - 1, $y);
    my $now = time;
    my $ago = $now - $then;
    my $fmt = "%Y-%m-%d %H:%M:%S UTC";
    printf STDERR "%s committed to dist: %s (r%s)\n", $name, strftime($fmt, gmtime $then), $rev;
    printf STDERR "%s current time:      %s\n", $name, strftime($fmt, gmtime $now);
    printf STDERR "%s elapsed:           %dh %02dm %02ds\n", $name,
      int($ago / 3600), int($ago % 3600 / 60), $ago % 60;
  ' "`basename "$1"`" "${rev}" "${committed}" || true
}

# cache_timing HEADERS   reports, from the response headers curl saved in
# HEADERS, the HTTP status and for how long a cache (the CDN) has been
# holding that response. Says nothing about caching if there is no Age header.
cache_timing() {
  perl -e '
    local $/;
    my $all = <>;
    defined $all or exit 0;
    $all =~ s/\r//g;
    # with redirects there is one header block per response, use the last
    my @blocks = grep { /^HTTP\// } split /\n\n+/, $all;
    my $h = $blocks[-1] or exit 0;
    my ($status) = $h =~ m{^HTTP/\S+\s+(\d+)};
    my ($age) = $h =~ /^age:\s*(\d+)/mi;
    my ($xcache) = $h =~ /^x-cache:\s*(.+)$/mi;
    if (defined $age) {
      printf STDERR "HTTP %s response has been cached for %dh %02dm %02ds (Age: %d%s)\n",
        $status, int($age / 3600), int($age % 3600 / 60), $age % 60, $age,
        defined $xcache ? ", X-Cache: $xcache" : "";
    } else {
      printf STDERR "HTTP %s response carries no Age header, so it was not served from a cache\n", $status;
    }
  ' "$1" || true
}

# downloads.apache.org syncs from SVN with some delay, and anything the CDN
# fetches in the meantime (an outdated file or a 404) stays cached for a while.
if dist_mode_is_local; then
  warn "DIST_MODE=local: nothing was published, skipping the downloads.apache.org/dlcdn check"
fi
for changes in "CHANGES_${VERSION}" "CHANGES_${v_major}.${v_minor}"; do
  if dist_mode_is_local; then
    break
  fi
  for base in "https://downloads.apache.org/${PROJECT}" "https://dlcdn.apache.org/${PROJECT}"; do
    echo "verifying ${base}/${changes} ..."
    # Fetch first so a failed download (typically a 404 because the file
    # has not been synced yet) is not reported as a content mismatch.
    fetched=`mktemp`
    headers=`mktemp`
    if ! curl -fsSL -D "${headers}" -o "${fetched}" "${base}/${changes}"; then
      sync_timing "${AO_DIST_RELEASE_PATH}/${changes}"
      cache_timing "${headers}"
      rm -f "${fetched}" "${headers}"
      fail "${base}/${changes} is not available yet (see the curl error above). Nothing is wrong: either the file has not been synced from SVN yet, or the CDN is still caching an earlier 404. Wait for it to appear, then rerun $0"
    fi
    if ! cmp -s "${fetched}" "${AO_DIST_RELEASE_PATH}/${changes}"; then
      sync_timing "${AO_DIST_RELEASE_PATH}/${changes}"
      cache_timing "${headers}"
      rm -f "${fetched}" "${headers}"
      fail "${base}/${changes} does not match SVN. Wait (the CDN cache expires within about 30 minutes) or ask ASF Infra to purge it, then rerun $0"
    fi
    rm -f "${headers}"
    rm -f "${fetched}"
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


CVES_MENTIONED=`fgrep CVE- "${AO_DIST_RELEASE_PATH}/CHANGES_${VERSION}" || true`
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
