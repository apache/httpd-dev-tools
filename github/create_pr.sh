#!/bin/bash
#
# This script creates a pull request against the 2.4.x branch to backport
# the given Subversion revisions from trunk.
# It requires that is executed in the root of a local clone of your fork
# of https://github.com/apache/httpd.git.
# In that clone two remotes are required:
# - origin  : which points to your fork
# - upstream: which points to https://github.com/apache/httpd.git
# Furthermore you need to have remote tracking branches for the trunk and
# 2.4.x branches in your clone that are tracked in your fork.
# Requires git and hub or gh be on the PATH.
# If gh is available it will be preferred over hub.


usage()
{
    echo "usage: $(basename $0) [-r] [-b branch name] [-t target branch name] <revision number> [revision numbers] ..."
    echo "\t\t -r: resume after handling merge conflicts from a previous run"
    exit
}

TARGET_BRANCH_NAME="2.4.x"
RESUME=0

if type -P gh > /dev/null ; then
    if ! gh auth status 2>&1|grep "Logged in to github.com" >/dev/null; then
        echo "You need to `gh auth login` before continuing"
        exit 1
    fi
fi

while getopts "hb:t:r" OPTION ; do
    case "$OPTION" in
        h) usage
           ;;
        b) BRANCH_NAME="$OPTARG"
           ;;
        t) TARGET_BRANCH_NAME="$OPTARG"
           ;;
        r) RESUME=1
           ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -lt 1 ] ; then
    usage
fi

if [ -z "$BRANCH_NAME" ] ; then
    BRANCH_NAME=`echo "$@" | tr " " _`
fi

git fetch upstream trunk

if ! git branch | grep -q $BRANCH_NAME ; then
    git checkout "$TARGET_BRANCH_NAME"
    if [ "$?" -ne 0 ] ; then
        exit
    fi
    git pull upstream "$TARGET_BRANCH_NAME"
    if [ "$?" -ne 0 ] ; then
        exit
    fi
    git checkout -b $BRANCH_NAME
    if [ "$?" -ne 0 ] ; then
        exit
    fi
else
    git checkout $BRANCH_NAME
    if [ "$?" -ne 0 ] ; then
        exit
    fi
fi

for i in "$@" ; do
#    COMMITS="$COMMITS $(git log --grep="git-svn-id: https://svn.apache.org/repos/asf/httpd/httpd/trunk@($i)" --left-right upstream/trunk...$BRANCH_NAME  --cherry-pick -P --pretty=format:%H)"
    POTENTIAL_COMMIT=$(git log --grep="git-svn-id: https://svn.apache.org/repos/asf/httpd/httpd/trunk@($i)" --left-only upstream/trunk...$BRANCH_NAME  --cherry-pick -P --pretty=format:%H)
    if [ -n "$POTENTIAL_COMMIT" ] ; then
        CHERRY_CHECK=$(git log --grep="cherry picked from commit $POTENTIAL_COMMIT" --right-only  upstream/trunk...$BRANCH_NAME -P --pretty=format:%H)
        if [ -z "$CHERRY_CHECK" ] ; then
            COMMITS="$COMMITS $POTENTIAL_COMMIT"
        fi
    fi
done

if [ $RESUME -eq 0 ]; then
  for i in $COMMITS ; do
      git cherry-pick -x $i
      if [ "$?" -ne 0 ] ; then
          exit
      fi
  done
fi

git push -u origin $BRANCH_NAME
MESSAGE=`echo "$@" | sed -e 's/ /, r/g'`
if type -P gh > /dev/null ; then
    RESULT=`gh pr create -B "$TARGET_BRANCH_NAME" -b "Merge r${MESSAGE} from trunk" --title "Merge r${MESSAGE} from trunk"`
else
    RESULT=`hub pull-request -b "apache:${TARGET_BRANCH_NAME}" -m "Merge r${MESSAGE} from trunk"`
fi
echo $RESULT
PR=`echo $RESULT | sed -e 's#.*/##'`

cat <<EOF
  *) module_name: What
     Trunk version of patch:
EOF

for i in "$@" ; do
    echo "        https://svn.apache.org/r$i"
done

cat <<EOF
     Backport version for $TARGET_BRANCH_NAME of patch:
       https://patch-diff.githubusercontent.com/raw/apache/httpd/pull/$PR.diff
     Can be applied via apply_backport_pr.sh $PR
     +1:
EOF

