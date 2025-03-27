#!/bin/bash
#
# This script adds one or more subversion trunk revisions to a PR created
# with ./create_pr.sh
# It requires that is executed in the root of a local clone of your fork
# of https://github.com/apache/httpd.git, with the PR branch checked out.
# Requires git and hub or gh be on the PATH.
# If gh is available it will be preferred over hub.


if [ "$#" -lt 1 ] ; then
    echo "usage: $(basename $0) <revision number> [revision numbers] ..."
    exit
fi

BRANCH_NAME=`git branch --show-current`

git fetch upstream trunk

for i in "$@" ; do
    i=${i#r}
#    COMMITS="$COMMITS $(git log --grep="git-svn-id: https://svn.apache.org/repos/asf/httpd/httpd/trunk@($i)" --left-right upstream/trunk...$BRANCH_NAME  --cherry-pick -P --pretty=format:%H)"
    POTENTIAL_COMMIT=$(git log --grep="git-svn-id: https://svn.apache.org/repos/asf/httpd/httpd/trunk@($i)" --left-only upstream/trunk...$BRANCH_NAME  --cherry-pick -P --pretty=format:%H)
    if [ -n "$POTENTIAL_COMMIT" ] ; then
        CHERRY_CHECK=$(git log --grep="cherry picked from commit $POTENTIAL_COMMIT" --right-only  upstream/trunk...$BRANCH_NAME -P --pretty=format:%H)
        if [ -z "$CHERRY_CHECK" ] ; then
            COMMITS="$COMMITS $POTENTIAL_COMMIT"
        fi
    fi
done

for i in $COMMITS ; do
    git cherry-pick -x $i
    if [ "$?" -ne 0 ] ; then
        exit
    fi
done
