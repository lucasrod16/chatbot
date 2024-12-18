#!/usr/bin/env bash

# user_data script log filepath on ec2 instance: /var/log/cloud-init-output.log

set -euox pipefail

# https://docs.aws.amazon.com/ebs/latest/userguide/ebs-using-volumes.html
# EBS volume is primarly used to persist open-webui chat data,
# models downloaded by ollama, and docker images.
mount_ebs_volume() {
    local volume_id="vol0f2153615108429a8"
    local timeout=15
    local interval=3
    local start_time
    start_time=$(date +%s)
    while ! lsblk --nvme | grep -q "$volume_id"; do
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        if [ "$elapsed" -ge "$timeout" ]; then
            echo "Error: Volume ($volume_id) is not attached. Ensure the EBS volume is attached."
            exit 1
        fi

        echo "Waiting for volume ($volume_id) to be attached... Retrying in $interval seconds."
        sleep $interval
    done


    local device_name
    device_name="/dev/$(lsblk --nvme | grep "vol0f2153615108429a8" | awk '{print $1}')"

    if file -s "$device_name" | grep "filesystem"; then
        echo "Device $device_name is already formatted."
    else
        echo "Formatting $device_name as ext4..."
        mkfs.ext4 "$device_name"
    fi

    local mount_point="/mnt/data"
    # https://docs.docker.com/engine/daemon/#daemon-data-directory
    local docker_data_directory="/var/lib/docker"

    if [ ! -d "$mount_point" ]; then
        echo "Creating mount point $mount_point..."
        mkdir -p "$mount_point"
    fi

     if [ ! -d "$docker_data_directory" ]; then
        echo "Creating docker mount point $docker_data_directory..."
        mkdir -p "$docker_data_directory"
    fi

    echo "Mounting $device_name to $mount_point..."
    mount "$device_name" "$mount_point"

    echo "Mounting $device_name to $docker_data_directory..."
    mount "$device_name" "$docker_data_directory"

    if mountpoint -q "$mount_point"; then
        echo "EBS volume successfully mounted at $mount_point."
    else
        echo "Error: Failed to mount $device_name at $mount_point."
        exit 1
    fi

    if mountpoint -q "$docker_data_directory"; then
        echo "EBS volume successfully mounted at $docker_data_directory."
    else
        echo "Error: Failed to mount $device_name at $docker_data_directory."
        exit 1
    fi

    echo "Creating directories within $mount_point..."
    mkdir -p "${mount_point}/ollama"
    mkdir -p "${mount_point}/open-webui"
}

# https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
install_docker() {
    # Add Docker's official GPG key:
    apt-get update -y 
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y

    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/index.html#pre-installation-actions
# https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/index.html#ubuntu
install_nvidia_driver() {
    # install kernel headers and development packages for the currently running kernel
    apt-get install -y "linux-headers-$(uname -r)"

    # install the cuda-keyring package
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb

    apt-get update -y

    # install open kernel modules
    apt-get install -y nvidia-open
}

# https://github.com/ollama/ollama/blob/main/docs/docker.md
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html#installing-the-nvidia-container-toolkit
install_nvidia_container_toolkit() {
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -y
    apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
}

mount_ebs_volume
install_docker
install_nvidia_driver
install_nvidia_container_toolkit
