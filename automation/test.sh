#!/bin/bash
#
# This file is part of the KubeVirt project
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
#
# Copyright 2017 Red Hat, Inc.
#

# CI considerations: $TARGET is used by the jenkins build, to distinguish what to test
# Currently considered $TARGET values:
#     kubernetes-release: Runs all functional tests on a release kubernetes setup
#     openshift-release: Runs all functional tests on a release openshift setup

set -ex

export CDI_NAMESPACE="cdi-$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 5 | head -n 1)"

echo "cdi-namespace: ${CDI_NAMESPACE}"

if [[ -n "$RANDOM_CR" ]]; then
  export CR_NAME="${CDI_NAMESPACE}"
fi

readonly ARTIFACTS_PATH="${ARTIFACTS}"
readonly BAZEL_CACHE="${BAZEL_CACHE:-http://bazel-cache.kubevirt-prow.svc.cluster.local:8080/kubevirt.io/containerized-data-importer}"

source hack/common-funcs.sh

export KUBEVIRT_PROVIDER=$TARGET

if [[ $TARGET =~ openshift-.* ]]; then
  export KUBEVIRT_PROVIDER="os-3.11.0-crio"
elif [[ $TARGET =~ k8s-.* ]]; then
  export KUBEVIRT_NUM_NODES=2
  export KUBEVIRT_MEMORY_SIZE=8192
elif [[ $TARGET =~ kind-.* ]]; then
  export KUBEVIRT_NUM_NODES=1
  export KIND_PORT_MAPPING=30085:30084
fi

if [ ! -d "cluster-up/cluster/$KUBEVIRT_PROVIDER" ]; then
  echo "The cluster provider $KUBEVIRT_PROVIDER does not exist"
  exit 1
fi

if [[ -n "$MULTI_UPGRADE" ]]; then
  export UPGRADE_FROM="v1.35.0 v1.37.0 v1.40.0 v1.49.0"
fi

# Don't upgrade if we are using a random CR name, otherwise the upgrade will fail
if [[ -z "$UPGRADE_FROM" ]] && [[ -z "$RANDOM_CR" ]]; then
  release_regex='release-v[0-9]+\.[0-9]+'
  if [[ "$PULL_BASE_REF" =~ $release_regex ]]; then
    # If target branch is a release branch, upgrade from previous y release to current PR
    # This is done to avoid downgrade from latest_gh_release to cherrypick_pr
    ver=$(echo "$PULL_BASE_REF" | cut -d 'v' -f 2)
    export UPGRADE_FROM=$(get_previous_y_release "kubevirt/containerized-data-importer" "$ver")
  else
    export UPGRADE_FROM=$(get_latest_release "kubevirt/containerized-data-importer")
  fi
  echo "Upgrading from versions: $UPGRADE_FROM"
fi

kubectl() { cluster-up/kubectl.sh "$@"; }

export CDI_NAMESPACE="${CDI_NAMESPACE:-cdi}"

make cluster-down
# Create .bazelrc to use remote cache
cat >ci.bazelrc <<EOF
startup --host_jvm_args=-Dbazel.DigestFunction=sha256
build --remote_local_fallback
build --remote_http_cache=${BAZEL_CACHE}
build --jobs=4
EOF

make cluster-up

# Wait for nodes to become ready
set +e
kubectl_rc=0
retry_counter=0
while [[ $retry_counter -lt 30 ]] && [[ $kubectl_rc -ne 0 || -n "$(kubectl get nodes --no-headers | grep NotReady)" ]]; do
    echo "Waiting for all nodes to become ready ..."
    kubectl get nodes --no-headers
    kubectl_rc=$?
    retry_counter=$((retry_counter + 1))
    sleep 10
done
set -e

if [ $retry_counter -eq 30 ]; then
	echo "Not all nodes are up"
	exit 1
fi

echo "Nodes are ready:"
kubectl get nodes

if [ "$KUBEVIRT_STORAGE" == "hpp" ] && [ "$CDI_E2E_FOCUS" == "Destructive" ]; then
  kubectl apply -f tests/manifests/snapshot
fi

make cluster-sync

kubectl version

echo "Nil check --PRE-- test run"
kubectl get pods -n $CDI_NAMESPACE -o'custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,RESTARTS:status.containerStatuses[*].restartCount' --no-headers

ginko_params="--test-args=--ginkgo.no-color --ginkgo.junit-report=${ARTIFACTS_PATH}/junit.functest.xml"

if [[ -n "$CDI_DV_GC" ]]; then
    kubectl patch cdi $CDI_NAMESPACE --type merge -p '{"spec": {"config": {"dataVolumeTTLSeconds": '$CDI_DV_GC'}}}'
fi

# Run functional tests
TEST_ARGS=$ginko_params make test-functional

echo "Nil check --POST-- test run"
kubectl get pods -n $CDI_NAMESPACE -o'custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,RESTARTS:status.containerStatuses[*].restartCount' --no-headers
kubectl logs -n $CDI_NAMESPACE $(kubectl get pod -n $CDI_NAMESPACE -l=cdi.kubevirt.io=cdi-deployment --output=jsonpath='{$.items[0].metadata.name}') --previous || echo "this is fine"
