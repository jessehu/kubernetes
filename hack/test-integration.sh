#!/bin/bash

# Copyright 2014 Google Inc. All rights reserved.
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

set -o errexit
set -o nounset
set -o pipefail

basedir=$(dirname "$0")
source "${basedir}/config-go.sh"

source "${KUBE_REPO_ROOT}/hack/util.sh"

cleanup() {
  kill "${ETCD_PID-}" >/dev/null 2>&1 || :
  rm -rf "${ETCD_DIR-}"
  echo ""
  echo "Complete"
}

if [[ "${KUBE_NO_BUILD_INTEGRATION+set}" != "set" ]]; then
    "${KUBE_REPO_ROOT}/hack/build-go.sh" cmd/integration
fi

# Run cleanup to stop etcd on interrupt or other kill signal.
trap cleanup HUP INT QUIT TERM

start_etcd

echo ""
echo "Integration test cases..."
echo ""
GOFLAGS="-tags 'integration no-docker'" \
  "${KUBE_REPO_ROOT}/hack/test-go.sh" test/integration

echo ""
echo "Integration scenario ..."
echo ""
"${KUBE_TARGET}/bin/integration"

cleanup
