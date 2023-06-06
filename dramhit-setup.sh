#!/bin/bash

set -eo pipefail

MOUNT_DIR=/opt/dramhit
LOG_FILE=${HOME}/dramhit-setup.log
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
  if [ ! -x "$(command -v nix-channel)" ]; then
    sh <(curl -L https://nixos.org/nix/install) --daemon
    if [ -f ${NIX_DAEMON_VARS} ]; then
      echo "sourcing ${NIX_DAEMON_VARS}"
      source ${NIX_DAEMON_VARS}
    fi
  else
    record_log "Nix already installed!";
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

  #sudo mkdir -p /nix
  #sudo mount -t ext4 /dev/sda4 /nix 

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

  sudo mkdir /nix
  sudo cp -r /nix ${MOUNT_DIR}
  sudo mount --bind ${MOUNT_DIR}/nix /nix

  install_dependencies
}

# Clone all repos
clone_incrementer() {
  if [ ! -d ${MOUNT_DIR}/incrementer ]; then
    record_log "Cloning incrementer"
    pushd ${MOUNT_DIR}
    git clone https://github.com/mars-research/dramhit-incrementer
    popd;
  else
    record_log "incrementer dir not empty! skipping..."
  fi
}

clone_dramhit() {
  if [ ! -d ${MOUNT_DIR}/dramhit ]; then
    record_log "Cloning dramhit..."
    pushd ${MOUNT_DIR}
    git clone https://github.com/KaminariOS/DRAMHiT.git --recursive dramhit
    popd;
  else
    record_log "dramhit dir not empty! skipping..."
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

declare -A DATASETS

DATASETS["dmela"]=${DATASET_DIR}/ERR4846928.fastq
DATASETS["fvesca"]=${DATASET_DIR}/SRR1513870.fastq

download_datasets() {
  mkdir -p ${DATASET_DIR}
  pushd ${DATASET_DIR}

  for file in ${DATASETS[@]}; do
    RAW_FILE=$(echo ${file} | cut -d'.' -f1)
    LOC=$(echo ${RAW_FILE} | awk -F'/' '{ print $NF }')

    if [ ! -f ${RAW_FILE} ]; then
      record_log "Downloading ${LOC} dataset"
      wget https://sra-pub-run-odp.s3.amazonaws.com/sra/${LOC}/${LOC}
    fi
  done

  if [ ! -f "SHA256SUMS" ]; then
    echo "4b358e9879d9dd76899bf0da3b271e2d7250908863cf5096baeaea6587f3e31e ERR4846928" > SHA256SUMS
    echo "5656e982ec7cad80348b1fcd9ab64c5cab0f0a0563f69749a9f7c448569685c1 SRR1513870" >> SHA256SUMS
  fi

  sha256sum -c SHA256SUMS

  if [ $? -ne 0 ]; then
    echo "Downloaded files likely corrupted!"
  fi
  popd
}

download_sratoolkit() {
  pushd ${MOUNT_DIR}

  if [ ! -d ${SRA_HOME} ]; then
    mkdir -p ${SRA_HOME}
    record_log "Downloading SRA toolkit."

    wget https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/current/sratoolkit.current-ubuntu64.tar.gz

    tar xvf sratoolkit.current-ubuntu64.tar.gz -C ${SRA_HOME} --strip-components=1
    rm sratoolkit.current-ubuntu64.tar.gz
  fi

  popd
}

clone_repos() {
  clone_incrementer
  clone_dramhit
  clone_chtkc
  download_datasets
  download_sratoolkit
}

## Build
build_incrementer() {
  record_log "Building incrementer"
  pushd ${MOUNT_DIR}/dramhit-incrementer
  nix-shell -p cmake gnumake --command "mkdir -p build && cd build; cmake .. && make -j $(nproc)"
  popd
}

build_dramhit() {
  record_log "Building dramhit"
  pushd ${MOUNT_DIR}/dramhit
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
  for file in ${DATASETS[@]}; do
    if [[ ! -f ${file} ]]; then
      RAW_FILE=$(echo ${file} | cut -d'.' -f1)
      ${SRA_HOME}/bin/fastq-dump ${RAW_FILE}
    fi
  done
  popd
}

build_all() {

  record_log "Processing fastq";
  process_fastq;
  record_log "Building incrementer";
  build_incrementer;
  record_log "Building dramhit";
  build_dramhit;
  record_log "Building chtkc";
  build_chtkc;
}

setup_system() {
  record_log "Running setup scripts"
  sudo ${MOUNT_DIR}/dramhit/scripts/min-setup.sh
}

setup_user() {

    record_log "Building flake";
    pushd /users/Kosumi
    nix build github:KaminariOS/nixpkgs/dev#homeConfigurations.shellhome.activationPackage --extra-experimental-features nix-command --extra-experimental-features flakes
    popd
    record_log "change own";
    sudo chown -R Kosumi /opt/dramhit
    sudo ln -s $(which nix-store) /usr/local/bin/nix-store
}

record_log "Prepare_machine";
prepare_machine;
record_log "Clone repos";
clone_repos;
record_log "Setting up system";
setup_system;
record_log "Build all";
build_all;
record_log "Setting user stuff";
setup_user;

#export TERM=linux
record_log "Done Setting up!"
