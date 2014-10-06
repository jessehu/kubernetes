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

function public-key {
  local dir=${HOME}/.ssh

  for f in $HOME/.ssh/{id_{rsa,dsa},*}.pub; do
    if [ -r $f ]; then
      echo $f
      return
    fi
  done

  echo "Can't find public key file..." 1>&2
  exit 1
}

DISK=./kube/kube.vmdk
GUEST_ID=debian7_64Guest
PUBLIC_KEY_FILE=${PUBLIC_KEY_FILE-$(public-key)}
SSH_OPTS="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"

# These need to be set

## vCenter settings
#export GOVC_URL=
#export GOVC_DATACENTER=
#export GOVC_DATASTORE=
#export GOVC_RESOURCE_POOL=
#export GOVC_NETWORK=
# Set GOVC_INSECURE if the host in GOVC_URL is using a certificate that cannot
# be verified (i.e. a self-signed certificate), but IS trusted.
#export GOVC_INSECURE=1

## VM instances settings
#export GOVC_GUEST_LOGIN='kube:kube'
#export KUBE_USER=kube
#export KUBE_USER_HOME=/home/$KUBE_USER

## Set to true if using external tools instead of Kubernetes to create VMs in vCenter
#export USE_EXTERNAL_INSTANCES=true
#export INSTANCE_RESOURCE_POOL=${GOVC_DATACENTER}/vm/the-resource-pool
#export KUBE_CLUSTER_NAME=

