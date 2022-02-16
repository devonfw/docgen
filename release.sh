#!/usr/bin/env bash
> release.log
exec > >(tee -i release.log)
exec 2>&1

CALL_PARAMS=$*

source "$(dirname "${0}")"/functions.sh

DEPLOYED=false

undoRelease() {
  if { [ $? -ne 0 ] || [ "$DRYRUN" = true ]; } && [ "$DEPLOYED" = true ];
  then
    cd $SCRIPT_PATH
    log_step "Drop all sonatype releases as the release script exited abnormally or it was a dryrun"
    pauseUntilKeyPressed
    
    doRunCommand "mvn nexus-staging:drop $MVN_SETTINGS $DEBUG $BATCH_MODE" false
    doRunCommand "git push origin :refs/tags/release/$RELEASE_VERSION" false
    
    gitCleanup
    cd $SCRIPT_PATH

    if [ "$DRYRUN" = true ]
    then
      exit 0
    else
      exit 1
    fi
  fi
  # redo popd manually, as this EXIT trap will overwrite the popd trap from functions.sh
  popd
}
trap 'undoRelease' EXIT ERR

echo ""
echo "##########################################"
echo ""
echo "Checking preconditions:"

# check preconditions
cd "$SCRIPT_PATH"

GIT_STATUS="$(git diff --shortstat && git status --porcelain)"
if [[ -z "$GIT_STATUS" ]]
then
  echo "  * Working copy clean, continuing release"
else
  echo -e "\e[91m  !ERR! Working copy not clean. Please make sure everything is committed and pushed.\e[39m"
  echo ""
  echo "git diff --shortstat && git status --porcelain"
  echo "$GIT_STATUS"
  exit 1
fi

# Check if we are in correct state
SED_OUT="$(sed -r -E -n 's@<revision>([^<]+)-SNAPSHOT</revision>@\1@p' pom.xml)"
if [[ -n "$SED_OUT" ]]
then
  echo "  * Detected development revision $SED_OUT"
else
  SED_OUT="$(sed -r -E -n 's@<revision>([0-9]+\.[0-9]+\.[0-9]+)</revision>@\1@p' pom.xml)"
  if [[ -n "$SED_OUT" ]]
  then
    echo -e "\e[91m  !ERR! Detected release revision $SED_OUT. This script is intended to be executed on -SNAPSHOT versions only.\e[39m"
    exit 1
  else
    echo -e "\e[91m  !ERR! No revision detected in pom.xml.\e[39m"
    exit 1
  fi
fi

ORIGIN="$(git config --get remote.origin.url)"
case "$ORIGIN" in
  *devonfw/docgen*) echo "  * Detected clone from $ORIGIN." ;;
  *) echo -e "\e[91m  !ERR! You are working on a fork, please make sure, you are releasing from devonfw/docgen#master\e[39m" && exit 1 ;;
esac
echo ""
echo "##########################################"
echo ""

log_step "Remove -SNAPSHOT from revision"
doRunCommand "sed -E -i 's@<revision>([^<]+)-SNAPSHOT</revision>@<revision>\1</revision>@' pom.xml"
SED_OUT="$(sed -r -E -n 's@<revision>([0-9]+\.[0-9]+\.[0-9]+)</revision>@\1@p' pom.xml)"
RELEASE_VERSION=$(trim $SED_OUT)
if [[ -z "$RELEASE_VERSION" ]]
then
  echo -e "\e[91m  !ERR! could not set release revision in /pom.xml\e[39m"
  exit 1
else 
  echo "Set release revision to $RELEASE_VERSION"
fi

log_step "Commit set release revision $RELEASE_VERSION"
doRunCommand "git add -u"
doRunCommand "git commit -m'Set release version $RELEASE_VERSION'"

log_step "Deploy Release ${RELEASE_VERSION}"
# need to activate beforehand to cleanup if an error occurred
DEPLOYED=true
doRunCommand "mvn deploy -Pdeploy"

log_step "Create Git Tag release/${RELEASE_VERSION}"
doRunCommand "git tag release/${RELEASE_VERSION}"

log_step "Increase revision and convert to SNAPSHOT"
SED_OUT="$(sed -r -E -n 's@<revision>([0-9]+)\.([0-9]+)\.([0-9]+)</revision>@\3@p' pom.xml)"
SED_OUT=$(trim $SED_OUT)
if [[ -z "$SED_OUT" ]]
then
  echo -e "\e[91m  !ERR! could not identify release revision in /pom.xml\e[39m"
  exit 1
else
  SED_OUT=$((SED_OUT+1))
  NEW_PATCH=$(printf "%03d\n" $SED_OUT)
  VERSION_PREFIX="$(sed -r -E -n 's@<revision>([0-9]+)\.([0-9]+)\.([0-9]+)</revision>@\1.\2.@p' pom.xml)"
  VERSION_PREFIX=$(trim $VERSION_PREFIX)
  NEW_VERSION="$VERSION_PREFIX$NEW_PATCH-SNAPSHOT"
  doRunCommand "sed -E -i 's@<revision>([^<]+)</revision>@<revision>$NEW_VERSION</revision>@' pom.xml"
fi

log_step "Commit set revision $NEW_VERSION"
doRunCommand "git add -u"
doRunCommand "git commit -m'Set next revision $NEW_VERSION'"

if [[ "$DRYRUN" = true ]]
then
  log_step "[DRYRUN] Review and Abort"
  cd $SCRIPT_PATH
  exit 0
else
  log_step "Publish Release"
  # Remove GA auth header in case of CI (workaround): https://github.community/t/how-to-push-to-protected-branches-in-a-github-action/16101/47
  doRunCommand "git -c "http.https://github.com/.extraheader=" push origin master"
  doRunCommand "git -c "http.https://github.com/.extraheader=" push origin release/$RELEASE_VERSION"
  doRunCommand "mvn nexus-staging:release $MVN_SETTINGS $DEBUG $BATCH_MODE"
fi