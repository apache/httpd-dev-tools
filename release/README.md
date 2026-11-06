# httpd release scripts/process

## Setup and prerequisites

1. make sure `jq` is in your path
2. have a checkout of https://svn.apache.org/repos/asf/httpd/dev-tools and set environment variable $DEV_TOOLS in the environment
3. have a clone of https://github.com/apache/httpd with the branch to
   release checked out (the project releases from git since the cutover;
   a svn working copy of the branch still works for older setups). With the
   usual layout of origin = your fork and upstream = apache/httpd the
   scripts use the `upstream` remote; see GIT_SRC_REMOTE in env.sh.

## preflight checks

1. Wherever you can best run the test suite(s), make sure it's passing on a clean tree
2. Make sure changes-entries/ is empty (apart from template.txt) and docs xforms have been built and committed
3. If there is security content:
   - Use `cveprocess_update.py --release` on all CVE's to make sure there are no stale version
     references. We often fill in the affected/fixed ranges when the CVE is accepted, but
     they may not make the next release.  Checkin the changes and cveprocess_put.py them
   - make sure the SECURITY repo tools/readiness.sh output agrees with what you think is ready.
   - Check open PR's on github to see if anyone had submitted patches for vulnerabilities
     being fixed, so you can `closes #xxx` to dispose/credit them.
   - After this, the security content is public but un-announced and the clock is ticking.
   - apply to trunk and note the revision in a scratchpad.
     The scratchpad should look something like this to be used by some security tools later for bulk 
     updates (e.g. update_svn_logs_with_cve.py)

     CVE-XXXX-yyyy-foo-bar
         trunk: 1912345
         2.4.x: 1912346

   - apply to 2.4.x and note the revision in a scratchpad.
4. Make sure the test suite(s) still passes (or wait/watch CI runs)

## Procedure

### Produce a candidate

1. `cd` to a local checkout of project the branch you want to release. 

   Make sure it's up to date and has no local changes.

   It's best to have a dedicated checkout used for releases, as the tools expect it to be clean
   (no unversioned files).

   For example `cd ~/asf/httpd-2.4.x-release`

2. If this is an initial release candidate, `rm -rf dist` to throw away the 
   state from the previous release

3. Prepare the release:

   ```
   $DEV_TOOLS/release/r0-make-candidate.sh rc1
   ```

   Review the output, including picking up any ready CVEs (based on tools/readiness.sh output)

   Monitor the CI run for the tag (svn) or candidate branch (git) getting
   pushed: https://github.com/apache/httpd/actions. In git mode the script
   prints the matching `gh run list` / `gh run watch` commands.

4. Prepare the tarballs: 

   ```
   $DEV_TOOLS/release/r1-make-tars.sh
   ```

   Pay attention as you will likely be prompted for gpg login.

5. Push tarballs for voting: 

   ```
   $DEV_TOOLS/release/r2-prep-vote.sh
   ```

   Tarballs are available at https://dist.apache.org/repos/dist/dev/ now
   and a draft email for voting is output and left in `dist/`.

6. Send the email, do your own testing, and monitor the thread

### Handle vote results

#### On vote failure

`$DEV_TOOLS/release/reset-candidate.sh` and start over with a new candidate.

#### On vote success

1. Push the release tarballs

   `$DEV_TOOLS/release/r3-push-release-tars.sh`

    - tars are moved to https://dist.apache.org/repos/dist/release/httpd/
      git: the candidate branch's commit is tagged $VERSION (annotated,
      signed unless GIT_SIGN_TAGS=0) and the branch $FULL_VERSION-candidate
      is deleted.
    - CHANGES_$VERSION and CHANGES_2.4 stay in dist/dev until r4, so they
      are never published without the CVE information.

2. Wait for files to be available
   - Validate <https://downloads.apache.org/httpd/> (within 15 minutes)
   - Validate <https://dlcdn.apache.org/httpd/>

     The directory listing can be cached for up to two hours, but validate that you
     can manually access the current release by manipulating the filenames you see from
     the previous release then move on (within 15 more minutes?)

3. Stage the other release artifacts:

   1. Confirm the 2.4.x backport revisions in the CVE JSON files, so they will be
      in the copies incorporated onto the website.

      If you were tracking the backports in a file, you can add the data with
      `tools/update_cvejson_with_revisions.py`

      ```
          tools/update_cvejson_with_revisions.py --dry-run httpd-2.4.NN.txt
          tools/update_cvejson_with_revisions.py httpd-2.4.NN.txt
          # Runs a series of tools/cveprocess_update.py CVE-xxxx/CVE.json --backport r1xxxx
          svn ci
          tools/update_cvejson_with_revisions.py --put httpd-2.4.NN.txt
          # runs a series of tools/cveprocess_put.py CVE-xxxx/CVE.json
      ```

      Compare the output/totals of tools/readiness.sh with tools/readiness.sh -B (should result in
      the same total).

      IMPORTANT: update The SVN checkout in the httpd-2.4.x-release dir you are running the release
      scripts from (dist/pmc)

   2. Run: `$DEV_TOOLS/release/r4-stage-release.sh`

      ALL CHANGES HERE ARE LOCAL ONLY

      - moves CHANGES_$VERSION and CHANGES_2.4 from dist/dev to dist/release
      - folds in CVE related information for CHANGES files (and fails if any CVE is missing)
      - moves CVEs to pmc/resolved
      -  update ./CHANGES ./STATUS ./include/ap_release.h
      - checks out and modifies project website

      To verify, just `git diff` with a focus on e.g. CHANGES for CVE handling.
      It is likely you will want to cleanup the SECURITY changes entries folded into STATUS
      because they often have unusual formatting and some redundant info.

      If the docs/ changes are all total noise, consider throwing them away with
      `git checkout -- docs`

4. Up until this point, everything can be reverted with:

   ```
   $DEV_TOOLS/release/reset-candidate.sh
   ```

5. Commit additional staged release artifacts:

   ```
   $DEV_TOOLS/release/r5-commit-staged-release.sh
   ```

   This commits all locally staged changes to repositories and website.

6. Validate the website updates.

   Shortly after the commit, buildbot transforms content from the main branch on 	git@github.com:/apache/httpd-site onto the asf-site branch. 

   1. Wait for the buildbot email (few minutes)
   2. Verify the asf-site branch:
      - <https://github.com/apache/httpd-site/blob/asf-site/output/security/vulnerabilities_24.html>
      - <https://github.com/apache/httpd-site/blob/asf-site/output/index.html>
   3. Verify <httpd.apache.org>:  make sure the index, download, and security report pages are
   updated.  

7. Send the announcements: 

   ```
   $DEV_TOOLS/release/r6-announce.sh
   ```

   Before the emails, the script checks that CHANGES_$VERSION and CHANGES_2.4 on
   downloads.apache.org and dlcdn.apache.org match SVN.

   If the check fails, the CDN is serving a stale copy. downloads.apache.org
   lags SVN by a few minutes after r5, and whatever dlcdn fetches in that
   window stays cached (about 30 minutes for 2.4.69). Avoid fetching the CHANGES
   files from dlcdn until downloads.apache.org shows the new Last-Modified.
   Wait and rerun r6, or ask ASF Infra (#asfinfra or an INFRA Jira) to purge.

   The script will guide you how to send the emails.

8. Process the CVES that were included.

   The released moved the included CVEs into the ../resolved/ directory and you also
   hopefully have a list of them from the notes taken while backporting.

   1. In <https://cveprocess.apache.org>

     - set CVE to READY on the cveprocess site

       This can be automated with cveprocess_update -r but make sure to not remove
       the "released in 2.4.68" timeline which is not present locally

     - save the CVE entry

     - Use the 'OSS/ASF Emails' tab for the emails you should send to oss-security
       and to Apache lists.

     - ASF Security will be notified and will submit to the CVE
       project and then set state to 'PUBLIC'.

   2. `tools/update_svn_logs_with_cve.py` generates a shell script that updates
       the 2.4.x SVN commits to includ the CVE names. 

       The input is a text file with stanzas like this which is just the way Eric
       tracks them locally (we could get it from CVE.json these days)

       ```
       CVE-2026-33857-oob_reads_in_ajp_get_functions
            trunk: 1933340
            2.4.x: 1933341
       ```

       This can be done manually with  `svn propedit --revprop -r... svn:log`

       IMPORTANT: You need to save and run the output of `tools/update_svn_logs_with_cve.py`
       it doesn't run the SVN commands directly.

9. Clean up prior release artifacts
   
   This does not always need action.

     - https://dist.apache.org/repos/dist/release/httpd (incl CHANGES_2.4.xx)

10. Review the CHANGES and https://httpd.apache.org/security/vulnerabilities_24.html 

     ... For style and tweak as needed. git@github.com:/apache/httpd-site has
     one-time copies of CVE.json, edit and commit and the site will be rebuilt
     immediately.
     
     Even if you are not picky about the style of
     https://httpd.apache.org/security/vulnerabilities_24.html it is
     critical to verify the expected CVEs are listed. This is built by CI during
     changes to git@github.com:/apache/httpd-site and can be broken if the
     exported CVE json is missing fields.
     
     If CHANGES is really bad, consider replacing the various CHANGES files on dist/httpd
     (which is dist/apache.org-dist from your working directory checkout for release scripts)

11. Moderate announcements
    If you are a moderator for announce@httpd.a.o or announce@a.o moderate your own announcement at https://webmod.apache.org/?action=frontpage
    
12. Add the release to bugzilla: 
    
    <https://bz.apache.org/bugzilla/editversions.cgi?action=add&product=Apache%20httpd-2>
13. Commit any tests for CVEs that were resolved in the release.


## Misc notes
The local checkout:
 - same as you otherwise use, e.g. a clone of https://github.com/apache/httpd
   with 2.4.x checked out (or, in svn mode, ^/httpd/httpd/branches/2.4.x)
 - make sure that it builds and passes the tests for you
 - make-candidate.sh checks if "changes-entries" is empty (template.txt is
   tolerated). Do
   > make update-changes
   to merge them all into CHANGES.
 - make-candidate.sh checks if there are no local, uncomitted changes

Handling of VERSIONs:
 - You *should* just specify the version suffix when creating the candidate
   in step 0 and let the scripts figure out the rest. Example:
   > $DEV_TOOLS/release/r0-make-candidate.sh rc1
   to make the "release candidate 1" of the current checkout version.
   This recorded in the local file ./dist/VERSION and used subsequently
   if you omit the version argument in later steps.
 - You *may* specify the complete version as argument to the scripts.
   But scripts will complain if you mispell and they are unable to find
   the results of previous steps.
 - If no version is given, the scripts will use the file ./dest/VERSION
   to detect the version you are working on.
   If that does not exist, the scripts will use the version they find in
   your local checkout (httpd: include/ap_release.h).

What r0-make-candidate.sh does:
 - svn: copies the current REVISION of your checkout to ^/httpd/httpd/tags/$VERSION-candidate
   git: pushes the current commit of your checkout to the server as branch
   $VERSION-candidate (no local branch is created)
 - Patches the $VERSION everywhere in the sources where needed
 - Rebuilds the docs/manual, so the version and current year is properly reflected there
 - commits this to the candidate ("Post $VERSION tag updates"); git: and pushes it
 NOTE:
 - it works on a checkout it creates locally in dist/$VERSION-candidate (svn
   checkout or shallow git clone of the candidate), it does not modify the
   checkout you run this in. Once the candidate is created, any further
   modifications of your local checkout won't affect it.
 - Say, you have not called a vote yet and someone comes with a late, important
   commit to the branch, you should:
   * run reset-candidate.sh (removes the candidate tag/branch and the dist directory)
   * svn update / git pull your local checkout
   * run r0-make-candidate.sh again

What r1-make-tars.sh does:
 - exports the candidate (svn export of ^/httpd/httpd/tags/$VERSION-candidate,
   or git archive of the candidate branch as fetched from the server)
   into dist/httpd-$VERSION
 - retrieves the latest APR/APU sources and adds them to dist/httpd-$VERSION/srclib
 - runs "buildconf" on the export
 - moves the srclib contents into dist/httpd-$VERSION-deps/httpd-$VERSION/srclib
   makes tarballs of the -deps subdir
 - makes tarballs of the dist/httpd-$VERSION dir
 - generates checksums of the tarballs
 - signs the tarballs using gpg2/gpg/pgp whatever is first available.
   If the gpg default key is not what you want, call the script by given
   it the key identifier (email) it should use as:
   > make-tars.sh -s email-id

What r2-prep-vote.sh does:
 - checks if the local files from "make-tars.sh" are found in dist directory
 - checks out https://dist.apache.org/repos/dist/dev/httpd inside dist
 - modifies this checkout by adding the tarballs, CHANGES_$major.$minor
   and patching Annoucement$major.$minor.*
 - prepares an email template for voting in dist/mail-vote-$VERSION.txt
 - asks you, if you want to commit the changes to dist.apache.org. You
   may skip this, do some last inspection and commit this yourself.

What r3-push-release-tars.sh does:
 - AFTER a passed vote on the candidate, this moves the candidate tars
   in dist.apache.org from the /dev location to the /release location.
   This removes a version suffix. So httpd-2.4.49-rc1.at.gz becomes
   httpd-2.4.49.at.gz in the release dir.
 - It moves the CURRENT-IS-$VERSION file
 - It leaves CHANGES_$VERSION and CHANGES_$v_major.$v_minor in /dev; r4
   moves them once the CVE information is added. Anything published to
   /release can be cached by the CDN (dlcdn.apache.org) for a long time.
 - svn: It moves SVN tags/$FULL_VERSION-candidate tag to tags/$VERSION
   git: It creates the annotated tag $VERSION on the candidate branch's
   commit, pushes it and deletes the candidate branch. Tags are never
   deleted or moved; rerunning r3 fails on the existing tag.
 - NO security related information is added yet.

What r4-stage-release.sh does:
 - It creates local checkouts for all the repositories that need updating
   * dist.apache.org/release/$PROJECT
   * $SVN_PMC_URL/$PROJECT where SECURITY information is kept
   * $GIT_SITE_URL where the project website files are kept
 - It moves CHANGES_$VERSION and CHANGES_$v_major.$v_minor from /dev to
   /release.
 - It retrieves the "ready" CVE list, adds the desription to the CHANGES
   files in the dist/release directory and the CHANGES in your local checkout
 - it moves the CVEs into the pmc/resolved directory, locally.
 - It updates dates and version numbers in the website files
 - It increments the version patch number and modifies your local
   checkout for work on the next version.
 - It lists you all files changed in those location and JUST EXITS.
 - Right, it does not commit the changes. You may do some manual inspection.

What r5-commit-staged-release.sh does:
 - It commits the changes made in the previous step in your local
   file system to the Apache repositories and website. This makes
   the SECURITY information publicly available via the release/CHANGES* files.
 - git: the local checkout is fast-forwarded first (`git pull --ff-only
   --autostash`); if the branch moved under the staged edits in a way that
   cannot fast-forward, the script stops and tells you to resolve it by
   hand. The commit is then pushed to GIT_SRC_URL.

What reset-candidate.sh does:
 - refuses if the release tag already exists
 - removes the candidate tarballs and CHANGES files from dist/dev
 - svn: removes tags/$FULL_VERSION-candidate
   git: deletes the candidate branch on the server (nothing else was touched:
   no tag was created and your branch was not modified)
 - removes the local dist directory

What r6-announce.sh does:
 - It checks that CHANGES_$VERSION and CHANGES_$v_major.$v_minor on
   downloads.apache.org and dlcdn.apache.org match SVN, and fails if not.
 - It reminds you what is still to do.
   * send a mail to the correct announce mailing lists
   * set the included CVEs on the Apache CVE process site to READY.
     so that those descriptions are sent to the relevant lists.
