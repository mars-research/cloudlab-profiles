#!/bin/bash

set -eo pipefail

MOUNT_DIR=/opt/kvstore
LOG_FILE=${HOME}/kvstore-setup.log
LLVM_VERSION=10
NIX_DAEMON_VARS="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
NIX_NO_DAEMON_VARS="$HOME/.nix-profile/etc/profile.d/nix.sh"
DATASET_DIR=${MOUNT_DIR}/kmer_dataset
SRA_HOME=${MOUNT_DIR}/sratoolkit

USER=${SUDO_USER}

if [[ ${USER} == "" ]]; then
  USER=$(id -u -n)
fi

if [[ ${SUDO_GID} == "" ]]; then
  GROUP=$(id -g -n)
else
  GROUP=$(getent group  | grep ${SUDO_GID} | cut -d':' -f1)
fi

record_log() {
  echo "[$(date)] $1" >> ${LOG_FILE}
}

install_nix_daemon() {
  sh <(curl -L https://nixos.org/nix/install) --daemon
  if [ -f ${NIX_DAEMON_VARS} ]; then
    echo "sourcing ${NIX_DAEMON_VARS}"
    source ${NIX_DAEMON_VARS}
  fi
}

install_nix_single_user() {
  sh <(curl -L https://nixos.org/nix/install) --no-daemon
  if [ -f ${NIX_NO_DAEMON_VARS} ]; then
    echo "sourcing ${NIX_NO_DAEMON_VARS}"
    source ${NIX_NO_DAEMON_VARS}
  fi
}

install_dependencies() {
  record_log "Begin setup!"
  record_log "Installing nix..."
  #install_nix_single_user
  install_nix_daemon
  nix-channel --list
}

create_extfs() {
  record_log "Creating ext4 filesystem on /dev/sda4"
  sudo mkfs.ext4 -Fq /dev/sda4
}

mountfs() {
  sudo mkdir -p ${MOUNT_DIR}
  sudo mount -t ext4 /dev/sda4 ${MOUNT_DIR}

  if [[ $? != 0 ]]; then
    record_log "Partition might be corrupted"
    create_extfs
    mountfs
  fi

  sudo chown -R ${USER}:${GROUP} ${MOUNT_DIR}
}

prepare_local_partition() {
  record_log "Preparing local partition ..."

  MOUNT_POINT=$(mount -v | grep "/dev/sda4" | awk '{print $3}' ||:)

  if [[ x"${MOUNT_POINT}" == x"${MOUNT_DIR}" ]];then
    record_log "/dev/sda4 is already mounted on ${MOUNT_POINT}"
    return
  fi

  if [ x$(sudo file -sL /dev/sda4 | grep -o ext4) == x"" ]; then
    create_extfs;
  fi

  mountfs
}

prepare_machine() {
  prepare_local_partition
  install_dependencies
}

# Clone all repos
clone_incrementer() {
  if [ ! -d ${MOUNT_DIR}/incrementer ]; then
    record_log "Cloning incrementer"
    pushd ${MOUNT_DIR}
    git clone https://github.com/daviddetweiler/incrementer
    popd;
  else
    record_log "incrementer dir not empty! skipping..."
  fi
}

clone_kvstore() {
  if [ ! -d ${MOUNT_DIR}/kvstore ]; then
    record_log "Cloning kvstore..."
    pushd ${MOUNT_DIR}
    git clone git@github.com:mars-research/kvstore --recursive
    popd;
  else
    record_log "kvstore dir not empty! skipping..."
  fi
}

clone_chtkc() {
  if [ ! -d ${MOUNT_DIR}/chtkc ]; then
    record_log "Cloning chtkc..."
    pushd ${MOUNT_DIR}
    git clone https://github.com/mars-research/chtkc.git --branch kmer-eval
    popd;
  else
    record_log "chtkc dir not empty! skipping..."
  fi
}

download_datasets() {
  mkdir -p ${DATASET_DIR}

  pushd ${DATASET_DIR}
  if [ ! -f "ERR4846928" ]; then
    wget https://sra-pub-run-odp.s3.amazonaws.com/sra/ERR4846928/ERR4846928
  fi

  if [ ! -f "SRR1513870" ]; then
    wget https://sra-pub-run-odp.s3.amazonaws.com/sra/SRR1513870/SRR1513870
  fi

  echo "4b358e9879d9dd76899bf0da3b271e2d7250908863cf5096baeaea6587f3e31e ERR4846928" > SHA256SUMS
  echo "5656e982ec7cad80348b1fcd9ab64c5cab0f0a0563f69749a9f7c448569685c1 SRR1513870" >> SHA256SUMS

  sha256sum -c SHA256SUMS
  if [ $? -ne 0 ]; then
    echo "Downloaded files likely corrupted!"
  fi
  popd
}

download_sratooklit() {
  pushd ${MOUNT_DIR}
  wget https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/current/sratoolkit.current-ubuntu64.tar.gz

  mkdir -p ${SRA_HOME}
  tar xvf sratoolkit.current-ubuntu64.tar.gz -C ${SRA_HOME} --strip-components=1
  rm sratoolkit.current-ubuntu64.tar.gz
  popd
}

clone_repos() {
  clone_incrementer
  clone_kvstore
  clone_chtkc
  download_datasets
  download_sratoolkit
}

## Build
build_incrementer() {
  record_log "Building incrementer"
  pushd ${MOUNT_DIR}/incrementer
  nix-shell -p cmake gnumake --command "mkdir -p build && cd build; cmake .. && make -j $(nproc)"
  popd
}

build_kvstore() {
  record_log "Building kvstore"
  pushd ${MOUNT_DIR}/kvstore
  nix-shell --command "mkdir -p build && cd build; cmake .. && make -j $(nproc)"
  popd
}

build_chtkc() {
  record_log "Building chtkc"
  pushd ${MOUNT_DIR}/chtkc
  nix-shell -p cmake gnumake zlib --command "mkdir -p build && cd build; cmake .. && make -j $(nproc)"
  popd
}

process_fastq() {
  record_log "Processing fastq files"
  pushd ${DATASET_DIR}
  source ${MOUNT_DIR}/chtkc/run_chtkc.sh
  for file in ${DATASET_ARRAY[@]}; do
    if [[ ! -f ${file} ]]; then
      SRA_FILE=$(echo ${file} | cut -d'.' -f1)
      ${SRA_HOME}/bin/fastq-dump ${SRA_FILE}
    fi
  done
  popd
}

build_all() {
  build_incrementer;
  build_kvstore;
  build_chtkc;
  process_fastq
}

prepare_machine;
clone_repos;
build_all;
record_log "Done Setting up!"
