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

# A library of helper functions and constants for the local config.

# Use the config file specified in $KUBE_CONFIG_FILE, or default to
# config-default.sh.
source $(dirname ${BASH_SOURCE})/${KUBE_CONFIG_FILE-"config-default.sh"}

function get-vm-ipath {
  vm_name=$1
  if [ "$USE_EXTERNAL_INSTANCES" == "true" ]; then
    vm_group=$(echo $vm_name | awk -F '-' '{print $2}')
    echo $INSTANCE_RESOURCE_POOL/$INSTANCE_PREFIX/$vm_group/$vm_name
  else
    echo $GOVC_DATACENTER/vm/$vm_name
  fi
}

function get-vm-ip {
  vm_name=$1
  vm_ipath=$(get-vm-ipath $vm_name)
  govc vm.ip -vm.ipath $vm_ipath
}

function detect-master {
  KUBE_MASTER=${MASTER_NAME}
  if [ -z "$KUBE_MASTER_IP" ]; then
    KUBE_MASTER_IP=$(get-vm-ip $KUBE_MASTER)
  fi
  if [ -z "$KUBE_MASTER_IP" ]; then
    echo "Could not detect Kubernetes master node.  Make sure you've launched a cluster with 'kube-up.sh'"
    exit 1
  fi
  echo "Found ${KUBE_MASTER} at ${KUBE_MASTER_IP}"
}

function detect-minions {
  KUBE_MINION_IP_ADDRESSES=()
  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    local minion_ip=$(get-vm-ip ${MINION_NAMES[$i]})
    echo "Found ${MINION_NAMES[$i]} at ${minion_ip}"
    KUBE_MINION_IP_ADDRESSES+=("${minion_ip}")
  done
  if [ -z "$KUBE_MINION_IP_ADDRESSES" ]; then
    echo "Could not detect Kubernetes minion nodes.  Make sure you've launched a cluster with 'kube-up.sh'"
    exit 1
  fi
}

# Verify prereqs on host machine
function verify-prereqs {
  if [ "$(which govc)" == "" ]; then
    echo "Can't find govc in PATH, please install and retry."
    echo ""
    echo "    go install github.com/vmware/govmomi/govc"
    echo ""
    exit 1
  fi
}

# Run command over ssh
function kube-ssh {
  local host=$1
  shift
  ssh ${SSH_OPTS} $KUBE_USER@${host} "$*"
}

# Instantiate a generic kubernetes virtual machine (master or minion)
function kube-up-vm {
  local vm_name=$1
  local vm_memory=$2
  local vm_cpu=$3
  local vm_ip=

  if [ "$USE_EXTERNAL_INSTANCES" != "true" ]; then
    govc vm.create \
      -debug \
      -m ${vm_memory} \
      -c ${vm_cpu} \
      -disk ${DISK} \
      -g ${GUEST_ID} \
      -link=true \
      ${vm_name}
  fi

  # Retrieve IP first, to confirm the guest operations agent is running.
  vm_ip=$(get-vm-ip ${vm_name})
  vm_ipath=$(get-vm-ipath ${vm_name})

  govc guest.mkdir \
    -vm.ipath ${vm_ipath} \
    -p \
    $KUBE_USER_HOME/.ssh

  govc guest.upload \
    -vm.ipath ${vm_ipath} \
    -f \
    ${PUBLIC_KEY_FILE} \
    $KUBE_USER_HOME/.ssh/authorized_keys
}

# Instantiate a kubernetes cluster
function kube-up {
  # Build up start up script for master
  KUBE_TEMP=$(mktemp -d -t kubernetes.XXXXXX)
  trap "rm -rf ${KUBE_TEMP}" EXIT

  get-password
  python $(dirname $0)/../third_party/htpasswd/htpasswd.py -b -c ${KUBE_TEMP}/htpasswd $user $passwd
  HTPASSWD=$(cat ${KUBE_TEMP}/htpasswd)

  echo "Starting master VM (this can take a minute)..."

  kube-up-vm ${MASTER_NAME} ${MASTER_MEMORY_MB-1024} ${MASTER_CPU-1}

  # Prints master IP, so user can log in for debugging.
  detect-master
  echo

  echo "Starting minion VMs (this can take a minute)..."

  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    (
      echo "#! /bin/bash"
      echo "MY_NAME=${MINION_NAMES[$i]}"
      grep -v "^#" $(dirname $0)/vsphere/templates/hostname.sh
      echo "MASTER_NAME=${MASTER_NAME}"
      echo "MASTER_IP=${KUBE_MASTER_IP}"
      echo "MINION_IP_RANGE=${MINION_IP_RANGES[$i]}"
      grep -v "^#" $(dirname $0)/vsphere/templates/salt-minion.sh
    ) > ${KUBE_TEMP}/minion-start-${i}.sh

    (
      kube-up-vm ${MINION_NAMES[$i]} ${MINION_MEMORY_MB-1024} ${MINION_CPU-1}

      MINION_IP=$(get-vm-ip ${MINION_NAMES[$i]})

      govc guest.upload \
        -vm.ipath $(get-vm-ipath ${MINION_NAMES[$i]}) \
        -perm 0700 \
        -f \
        ${KUBE_TEMP}/minion-start-${i}.sh \
        $KUBE_USER_HOME/minion-start.sh

      # Kickstart start script
      kube-ssh ${MINION_IP} "nohup sudo ~/minion-start.sh < /dev/null 1> minion-start.out 2> minion-start.err &"
    ) &
  done

  FAIL=0
  for job in `jobs -p`
  do
      wait $job || let "FAIL+=1"
  done
  if (( $FAIL != 0 )); then
    echo "${FAIL} commands failed.  Exiting."
    exit 2
  fi

  # Print minion IPs, so user can log in for debugging.
  detect-minions
  echo

  # Continue provisioning the master.

  (
    echo "#! /bin/bash"
    echo "MY_NAME=${MASTER_NAME}"
    grep -v "^#" $(dirname $0)/vsphere/templates/hostname.sh
    echo "MASTER_NAME=${MASTER_NAME}"
    echo "MASTER_HTPASSWD='${HTPASSWD}'"
    grep -v "^#" $(dirname $0)/vsphere/templates/install-release.sh
    grep -v "^#" $(dirname $0)/vsphere/templates/salt-master.sh
  ) > ${KUBE_TEMP}/master-start.sh

  vm_ipath=$(get-vm-ipath ${MASTER_NAME})
  govc guest.upload \
    -vm.ipath ${vm_ipath} \
    -perm 0700 \
    -f \
    ${KUBE_TEMP}/master-start.sh \
    $KUBE_USER_HOME/master-start.sh

  govc guest.upload \
    -vm.ipath ${vm_ipath} \
    -f \
    ./_output/release/master-release.tgz \
    $KUBE_USER_HOME/master-release.tgz

  # Kickstart start script
  kube-ssh ${KUBE_MASTER_IP} "nohup sudo ~/master-start.sh < /dev/null 1> master-start.out 2> master-start.err &"

  echo "Waiting for cluster initialization."
  echo
  echo "  This will continually check to see if the API for kubernetes is reachable."
  echo "  This might loop forever if there was some uncaught error during start up."
  echo

  until $(curl --insecure --user ${user}:${passwd} --max-time 5 \
          --fail --output /dev/null --silent https://${KUBE_MASTER_IP}/api/v1beta1/pods); do
      printf "."
      sleep 2
  done

  echo "Kubernetes cluster created."
  echo

  echo "Sanity checking cluster..."

  sleep 5

  # Don't bail on errors, we want to be able to print some info.
  set +e

  # Basic sanity checking
  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
      # Make sure docker is installed and started
      kube-ssh ${KUBE_MINION_IP_ADDRESSES[$i]} nohup sudo service docker start
      if [ "$?" != "0" ]; then
          echo "Docker failed to install on ${MINION_NAMES[$i]}. Your cluster is unlikely to work correctly."
          echo "Please run ./cluster/kube-down.sh and re-create the cluster. (sorry!)"
          exit 1
      fi
  done

  echo
  echo "Kubernetes cluster is running. The master is running at:"
  echo
  echo "  https://${KUBE_MASTER_IP}"
  echo
  echo "The user name and password to use is located in ~/.kubernetes_auth."
  echo
  echo "Security note: The server above uses a self signed certificate."
  echo "This is subject to \"Man in the middle\" type attacks."
  echo
}

# Delete a kubernetes cluster
function kube-down {
  govc vm.destroy ${MASTER_NAME} &

  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    govc vm.destroy ${MINION_NAMES[i]} &
  done

  wait

}

# Update a kubernetes cluster with latest source
function kube-push {
  detect-master

  vm_ipath=$(get-vm-ipath ${MASTER_NAME})
  govc guest.upload \
    -vm.ipath ${vm_ipath} \
    -f \
    ./_output/release/master-release.tgz \
    $KUBE_USER_HOME/master-release.tgz

  (
    grep -v "^#" $(dirname $0)/vsphere/templates/install-release.sh
    echo "echo Executing configuration"
    echo "sudo salt '*' mine.update"
    echo "sudo salt --force-color '*' state.highstate"
  ) | kube-ssh ${KUBE_MASTER_IP} bash

  get-password

  echo
  echo "Kubernetes cluster is updated.  The master is running at:"
  echo
  echo "  https://${KUBE_MASTER_IP}"
  echo
  echo "The user name and password to use is located in ~/.kubernetes_auth."
  echo
}

# Execute prior to running tests to build a release if required for env
function test-build-release {
	echo "TODO"
}

# Execute prior to running tests to initialize required structure
function test-setup {
	echo "TODO"
}

# Execute after running tests to perform any required clean-up
function test-teardown {
	echo "TODO"
}

# Set the {user} and {password} environment values required to interact with provider
function get-password {
  file=${HOME}/.kubernetes_auth
  if [ -e ${file} ]; then
    user=$(cat $file | python -c 'import json,sys;print(json.load(sys.stdin)["User"])')
    passwd=$(cat $file | python -c 'import json,sys;print(json.load(sys.stdin)["Password"])')
    return
  fi
  user=admin
  passwd=$(python -c 'import string,random; print("".join(random.SystemRandom().choice(string.ascii_letters + string.digits) for _ in range(16)))')

  # Store password for reuse.
  cat << EOF > ~/.kubernetes_auth
{
  "User": "$user",
  "Password": "$passwd"
}
EOF
  chmod 0600 ~/.kubernetes_auth
}
