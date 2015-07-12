#!/bin/bash

# Copyright 2014 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Bumps the version number by creating a couple of commits.

set -o errexit
set -o nounset
set -o pipefail

KUBE_ROOT=$(dirname "${BASH_SOURCE}")/..

NEW_VERSION=${1-}

fetch_url=$(git remote -v | grep GoogleCloudPlatform/kubernetes.git | grep fetch | awk '{ print $2 }')
if ! push_url=$(git remote -v | grep GoogleCloudPlatform/kubernetes.git | grep push | awk '{ print $2 }'); then
  push_url="https://github.com/GoogleCloudPlatform/kubernetes.git"
fi
fetch_remote=$(git remote -v | grep GoogleCloudPlatform/kubernetes.git | grep fetch | awk '{ print $1 }')

VERSION_REGEX="^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"
[[ ${NEW_VERSION} =~ $VERSION_REGEX ]] || {
  echo "!!! You must specify the version in the form of '$VERSION_REGEX'" >&2
  exit 1
}

VERSION_MAJOR="${BASH_REMATCH[1]}"
VERSION_MINOR="${BASH_REMATCH[2]}"
VERSION_PATCH="${BASH_REMATCH[3]}"

if ! git diff HEAD --quiet; then
  echo "!!! You must not have any uncommitted changes when running this command"
  exit 1
fi

if ! git diff-files --quiet pkg/version/base.go; then
  echo "!!! You have changes in 'pkg/version/base.go' already."
  exit 1
fi

release_branch="release-${VERSION_MAJOR}.${VERSION_MINOR}"
current_branch=$(git rev-parse --abbrev-ref HEAD)

if [[ "${VERSION_PATCH}" != "0" ]]; then
  # sorry, no going back in time, pull latest from upstream
  git remote update > /dev/null 2>&1

  if git ls-remote --tags --exit-code ${fetch_url} refs/tags/${NEW_VERSION} > /dev/null; then
    echo "!!! You are trying to tag ${NEW_VERSION} but it already exists.  Stop it!"
    exit 1
  fi

  last_version="v${VERSION_MAJOR}.${VERSION_MINOR}.$((VERSION_PATCH-1))"
  if ! git ls-remote --tags --exit-code ${fetch_url} refs/tags/${last_version} > /dev/null; then
    echo "!!! You are trying to tag ${NEW_VERSION} but ${last_version} doesn't even exist!"
    exit 1
  fi

  # this is rather magic.  This checks that HEAD is a descendant of the github branch release-x.y
  branches=$(git branch --contains $(git ls-remote --heads ${fetch_url} refs/heads/${release_branch} | cut -f1) ${current_branch})
  if [[ $? -ne 0 ]]; then
    echo "!!! git failed, I dunno...."
    exit 1
  fi

  if [[ ${branches} != "* ${current_branch}" ]]; then
    echo "!!! You are trying to tag to an existing minor release but branch: ${release_branch} is not an ancestor of ${current_branch}"
    exit 1
  fi
fi

SED=sed
if which gsed &>/dev/null; then
  SED=gsed
fi
if ! ($SED --version 2>&1 | grep -q GNU); then
  echo "!!! GNU sed is required.  If on OS X, use 'brew install gnu-sed'."
fi

echo "+++ Versioning documentation and examples"

# Update the docs to match this version.
DOCS_TO_EDIT=(docs/README.md examples/README.md)
for DOC in "${DOCS_TO_EDIT[@]}"; do
  $SED -ri \
      -e '/<!-- BEGIN STRIP_FOR_RELEASE -->/,/<!-- END STRIP_FOR_RELEASE -->/d' \
      -e "s/HEAD/${NEW_VERSION}/" \
      "${DOC}"
done

# Update API descriptions to match this version.
$SED -ri -e "s|(releases.k8s.io)/[^/]*|\1/${NEW_VERSION}|" pkg/api/v[0-9]*/types.go

${KUBE_ROOT}/hack/run-gendocs.sh
${KUBE_ROOT}/hack/update-swagger-spec.sh
git commit -am "Versioning docs and examples for ${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"

dochash=$(git log -n1 --format=%H)

VERSION_FILE="${KUBE_ROOT}/pkg/version/base.go"

GIT_MINOR="${VERSION_MINOR}.${VERSION_PATCH}"
echo "+++ Updating to ${NEW_VERSION}"
$SED -ri -e "s/gitMajor\s+string = \"[^\"]*\"/gitMajor string = \"${VERSION_MAJOR}\"/" "${VERSION_FILE}"
$SED -ri -e "s/gitMinor\s+string = \"[^\"]*\"/gitMinor string = \"${GIT_MINOR}\"/" "${VERSION_FILE}"
$SED -ri -e "s/gitVersion\s+string = \"[^\"]*\"/gitVersion string = \"$NEW_VERSION\"/" "${VERSION_FILE}"
gofmt -s -w "${VERSION_FILE}"

echo "+++ Committing version change"
git add "${VERSION_FILE}"
git commit -m "Kubernetes version $NEW_VERSION"

echo "+++ Tagging version"
git tag -a -m "Kubernetes version $NEW_VERSION" "${NEW_VERSION}"

echo "+++ Updating to ${NEW_VERSION}-dev"
$SED -ri -e "s/gitMajor\s+string = \"[^\"]*\"/gitMajor string = \"${VERSION_MAJOR}\"/" "${VERSION_FILE}"
$SED -ri -e "s/gitMinor\s+string = \"[^\"]*\"/gitMinor string = \"${GIT_MINOR}\+\"/" "${VERSION_FILE}"
$SED -ri -e "s/gitVersion\s+string = \"[^\"]*\"/gitVersion string = \"$NEW_VERSION-dev\"/" "${VERSION_FILE}"
gofmt -s -w "${VERSION_FILE}"

echo "+++ Committing version change"
git add "${VERSION_FILE}"
git commit -m "Kubernetes version ${NEW_VERSION}-dev"

echo "+++ Constructing backmerge branches"

function return_to_kansas {
  git checkout -f "${current_branch}"
}
trap return_to_kansas EXIT

backmerge="v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}-merge-to-master"
backmergetmp="${backmerge}-tmp-$(date +%s)"

# Now we create a temporary branch to revert the doc commit, then
# create the backmerge branch for the convenience of the user.
git checkout -b "${backmergetmp}"
git revert "${dochash}" --no-edit
git checkout -b "${backmerge}" "${fetch_remote}/master"
git merge -s recursive -X ours "${backmergetmp}" -m "${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH} merge to master"

git checkout "${current_branch}"
git branch -D "${backmergetmp}"

echo ""
echo "Success you must now:"
echo ""
echo "- Push the tag:"
echo "   git push ${push_url} v${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"
echo "   - Please note you are pushing the tag live BEFORE your PRs."
echo "       You need this so the builds pick up the right tag info."
echo "       If something goes wrong further down please fix the tag!"
echo "       Either delete this tag and give up, fix the tag before your next PR,"
echo "       or find someone who can help solve the tag problem!"
echo ""

if [[ "${VERSION_PATCH}" != "0" ]]; then
  echo "- Send branch: ${current_branch} as a PR to ${release_branch} <-- NOTE THIS"
  echo "- Get someone to review and merge that PR"
  echo ""
fi

echo "- I created the branch ${backmerge} for you. What I don't know is if this is"
echo "  the latest version. If it is, AND ONLY IF IT IS, submit this branch as a pull"
echo "  request to master:"
echo ""
echo "   git push <personal> ${backmerge}"
echo ""
echo "  and get someone to approve that PR. I know this branch looks odd. The purpose of this"
echo "  branch is to get the tag for the version onto master for things like 'git describe'."
echo ""
echo "  IF THIS IS NOT THE LATEST VERSION YOU WILL CAUSE TIME TO GO BACKWARDS. DON'T DO THAT, PLEASE."
echo ""

if [[ "${VERSION_PATCH}" == "0" ]]; then
  echo "- Push the new release branch"
  echo "   git push ${push_url} ${current_branch}:${release_branch}"
fi
