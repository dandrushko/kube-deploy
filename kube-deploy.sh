#!/bin/bash

export VNODE_NETWORKS=('pxe' 'mgmt')
export SSH_KEY=${SSH_KEY:-mcp.rsa}
export SALT_MASTER="192.168.10.100"
export BASE_IMAGE="https://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img"
export SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY}"
export VNODES=('cfg01' 'kube01' 'kube02')
export CLUSTER_DOMAIN="kube.local"
export vnodes_ram=(["cfg01"]="4096" ["kube01"]="4096" ["kube02"]="4096")
export vnodes_vcpus=(["cfg01"]="2" ["kube01"]="2" ["kube02"]="2")

generate_ssh_key() {
  [ -f "${SSH_KEY}" ] || ssh-keygen -f "${SSH_KEY}" -N ''
}


get_base_image() {
  [ -d images ] || mkdir -p images
  [ -f /tmp/${BASE_IMAGE/*\/} ] || wget -P /tmp -nc "${BASE_IMAGE}"
}


infra_cleanup(){
    cleanup_vms
    cleanup_networks
    rm $SSH_KEY
    rm -rf images
}


cleanup_networks() {
  for net in "${VNODE_NETWORKS[@]}"; do
    if virsh net-info "${net}" >/dev/null 2>&1; then
      virsh net-destroy "${net}"
      virsh net-undefine "${net}"
    fi
  done
}


cleanup_vms() {
  for node in $(virsh list --name | grep -P '\w{3}\d{2}'); do
    virsh destroy "${node}"
    virsh undefine "${node}"
  done
  for node in $(virsh list --name --all | grep -P '\w{3}\d{2}'); do
    virsh domblklist "${node}" | awk '/^.da/ {print $2}' | \
      xargs --no-run-if-empty -I{} sudo rm -f {}
    virsh undefine "${node}" --remove-all-storage --nvram
  done
}


create_networks() {
  for net in "${VNODE_NETWORKS[@]}"; do
    # in case of custom network, host should already have the bridge in place
    if [ -f "net_${net}.xml" ]; then
      virsh net-define "net_${net}.xml"
      virsh net-autostart "${net}"
      virsh net-start "${net}"
    fi
  done
}

prepare_vms() {
  get_base_image
  envsubst < user-data.template > user-data.sh

  for node in "${VNODES[@]}"; do
    # create/prepare images
    ./create-config-drive.sh -k "${SSH_KEY}.pub" -u user-data.sh \
       -h "${node}" "images/kube_${node}.iso"
    cp "/tmp/${BASE_IMAGE/*\/}" "images/kube_${node}.qcow2"
    qemu-img resize "images/kube_${node}.qcow2" 40G
  done

# add network settings
  net_args=""
  for net in "${VNODE_NETWORKS[@]}"; do
    net_args="${net_args} --network network=${net},model=virtio"
  done

# create vms with specified options
  for node in "${VNODES[@]}"; do
    virt-install --name "${node}" \
    --ram "${vnodes_ram[$node]}" --vcpus "${vnodes_vcpus[$node]}" \
    --cpu host-passthrough --accelerate ${net_args} \
    --disk path="$(pwd)/images/kube_${node}.qcow2",format=qcow2,bus=virtio,cache=none,io=native \
    --os-type linux --os-variant none \
    --boot hd --vnc --console pty --autostart --noreboot \
    --disk path="$(pwd)/images/kube_${node}.iso",device=cdrom \
    --noautoconsole \
    ${virt_extra_args}
  done
}

update_pxe_network() {
  if virsh net-info "pxe" >/dev/null 2>&1; then
    # set static ip address for salt master node, only if managed via virsh
    # NOTE: below expr assume PXE network is always the first in domiflist
    virsh net-update pxe add ip-dhcp-host \
    "<host mac='$(virsh domiflist cfg01 | awk '/network/ {print $5; exit}')' name='cfg01' ip='${SALT_MASTER}'/>" --live
  fi
}


start_vms() {
  # start vms
  for node in "${VNODES[@]}"; do
    virsh start "${node}"
    sleep $[RANDOM%5+1]
  done
}

check_connection() {
  local total_attempts=60
  local sleep_time=5
  local attempt=1

  set +e
  echo '[INFO] Attempting to get into foundation node ...'

  # wait until ssh on Salt master is available
  while ((attempt <= total_attempts)); do
    ssh ${SSH_OPTS} "ubuntu@${SALT_MASTER}" uptime
    case $? in
      0) echo "${attempt}> Success"; break ;;
      *) echo "${attempt}/${total_attempts}> ssh server ain't ready yet, waiting for ${sleep_time} seconds ..." ;;
    esac
    sleep $sleep_time
    ((attempt+=1))
  done
  set -e
}


salt_master_install() {
    set -e
    ssh ${SSH_OPTS} ubuntu@${SALT_MASTER} bash -s << INSTALL_END
    sudo -i
    echo -n 'Checking out cloud-init was completed ...'
    while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo -n '.'; sleep 1; done
    echo ' done'
    apt install -y subversion
    mkdir /srv/salt
    svn export --force https://github.com/salt-formulas/salt-formulas-scripts/trunk /srv/salt/scripts
    git clone https://github.com/Mirantis/reclass-system-salt-model /srv/salt/reclass/classes/system
    cd /srv/salt/scripts
    BOOTSTRAP_SALTSTACK_OPTS=" -r -dX stable 2016.11 " \
      MASTER_HOSTNAME=cfg01.${CLUSTER_DOMAIN} DISTRIB_REVISION=nightly \
        ./salt-master-init.sh
    salt-key -Ay

INSTALL_END
}


start_deployment(){
    generate_ssh_key
    create_networks
    prepare_vms
    update_pxe_network
    start_vms
    check_connection
    ### Assuming infra deployed at this point
    salt_master_install
}


while getopts ":cd" OPTION
do
    case $OPTION in
        c)
	    infra_cleanup
            ;;
        d)

	    start_deployment
	    ;;
        *)
            echo "[ERROR] Invalid arugent provided"
            exit 1
            ;;
    esac
done


####
#
# Salt master deployment
#
##


# gid modules to be added!!
BOOTSTRAP_SALTSTACK_OPTS=" -r -dX stable 2016.11 "
MASTER_HOSTNAME=cfg01.${CLUSTER_DOMAIN} DISTRIB_REVISION=nightly
##  BOOTSTRAP_SALTSTACK_OPTS=" -r -dX stable 2016.11 "  MASTER_HOSTNAME=cfg01.${CLUSTER_DOMAIN} DISTRIB_REVISION=nightly ./salt-master-init.sh
