#!/bin/bash
#Vitalytics Linux Bootstrap


usage() {
    echo "Usage: $0 -p <password> [-m <module>]"
    echo "  -p: Required password for SMTP relay"
    echo "  -m: Optional module to run (setupusers|nvidia|rpms|rmm|postrun|settime|docker|markdone)"
    exit 1
}

while getopts ":p:m:" opt; do
    case ${opt} in
        p)
            SMTP_PASSWORD=$OPTARG
            ;;
        m)
            MODULE=$OPTARG
            ;;
        \?)
            echo "Invalid option: $OPTARG" 1>&2
            usage
            ;;
        :)
            echo "Invalid option: $OPTARG requires an argument" 1>&2
            usage
            ;;
    esac
done

if [ -z "$SMTP_PASSWORD" ]; then
    echo "ERROR: Password is required"
    usage
fi

send_email() {
    local subject="$1"
    local body="$2"
    local smtp_server="smtp.office365.com"
    local smtp_port="587"
    local smtp_user="SMTP_relay@vitalytics.co.uk"
    local recipient="support@vitalytics.co.uk"

    # Install required packages if not present
    pkg_manager=$(get_package_manager)
    case $pkg_manager in
        nix)
            nix-env -iA nixpkgs.s-nail
            ;;
        dnf)
            dnf install -y s-nail
            ;;
        apt)
            apt-get update && apt-get install -y s-nail
            ;;
    esac

    cat > ~/.mailrc << EOF
set smtp=$smtp_server:$smtp_port
set smtp-use-starttls
set smtp-auth=login
set smtp-auth-user=$smtp_user
set smtp-auth-password=$SMTP_PASSWORD
set ssl-verify=ignore
set nss-config-dir=/etc/pki/nssdb/
EOF

    chmod 600 ~/.mailrc

    echo "$body" | s-nail -s "$subject" \
        -r "$smtp_user" \
        "$recipient"

    rm -f ~/.mailrc
}

if [ $EUID -ne 0 ]; then
    echo "ERROR: Must be run as root"
    exit 1
fi

HAS_SYSTEMD=$(ps --no-headers -o comm 1)
if [ "${HAS_SYSTEMD}" != 'systemd' ]; then
    echo "This bootstrap script only supports systemd"
    echo "Please install systemd or manually create the service using your systems's service manager"
    exit 1
fi

if [[ $DISPLAY ]]; then
    echo "ERROR: Display detected. Installer only supports running headless, i.e from ssh."
    echo "If you cannot ssh in then please run 'sudo systemctl isolate multi-user.target' to switch to a non-graphical user session and run the installer again."
    echo "If you are already running headless, then you are probably running with X forwarding which is setting DISPLAY, if so then simply run"
    echo "unset DISPLAY"
    echo "to unset the variable and then try running the installer again"
    exit 1
fi

MODULE=$1
HOSTNAME=$(hostname | cut -f1 -d.)
hostname $HOSTNAME
FQDN=`hostname -f`
IP=`hostname -i`
DC=$(echo ${HOSTNAME} | cut -c1-2)
ROLE=$(echo ${HOSTNAME} | cut -c5-6)
ENV=$(echo ${HOSTNAME} | cut -c3-4)
XY=$(echo ${HOSTNAME} | cut -c7-8)
YZ=$(echo ${HOSTNAME} | cut -c8-9)
POD=$(echo ${HOSTNAME} | cut -c7)
MREPO=${DC}${POD}mrepo
LPOD=${DC}${POD}
ENTITY=${YZ}
OS=$(echo ${HOSTNAME} | cut -c10)
#GATEWAY=$(grep GATEWAY /etc/sysconfig/network-scripts/ifcfg-eth0 /etc/sysconfig/network | head -1 | cut -d= -f 2)
DMI=$(/usr/sbin/dmidecode -s system-manufacturer)
OS_VERSION=$(lsb_release -d | awk '{print $6}' | awk 'BEGIN { FS="." } { print $1 }')

get_package_manager() {
    if command -v nix-env >/dev/null 2>&1; then
        echo "nix"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    else
        echo "unknown"
    fi
}

install_package() {
    local pkg_manager=$(get_package_manager)
    local packages=("$@")

    case $pkg_manager in
        nix)
            nix-env -iA nixpkgs.{$(echo "${packages[@]}" | tr ' ' ',')}
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
        apt)
            apt-get update
            apt-get install -y "${packages[@]}"
            ;;
        *)
            echo "Unsupported package manager"
            return 1
            ;;
    esac
}

update_system() {
    local pkg_manager=$(get_package_manager)
    
    case $pkg_manager in
        nix)
            nix-channel --update
            nix-env -u
            ;;
        dnf)
            dnf update -y
            ;;
        apt)
            apt-get update && apt-get upgrade -y
            ;;
        *)
            echo "Unsupported package manager"
            return 1
            ;;
    esac
}

function setupusers () {
    if id "rootasp" &>/dev/null; then
        echo "User 'rootasp' already exists. Updating password..."
        echo -e "${SMTP_PASSWORD}\n${SMTP_PASSWORD}" | passwd rootasp
    else
        useradd -m rootasp
        echo -e "${SMTP_PASSWORD}\n${SMTP_PASSWORD}" | passwd rootasp
        if id "rootasp" &>/dev/null; then
            echo "User 'rootasp' created successfully."
        else
            echo "Failed to create user 'rootasp'."
            exit 1
        fi
    fi

    if sudo -l -U rootasp | grep -q '(ALL) NOPASSWD: ALL'; then
        echo "User 'rootasp' can already run sudo without a password."
    else
        echo "rootasp ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/rootasp
        if sudo -l -U rootasp | grep -q '(ALL) NOPASSWD: ALL'; then
            echo "User 'rootasp' can now run sudo without a password."
        else
            echo "Failed to configure user 'rootasp' for passwordless sudo."
            exit 1
        fi
    fi
}
#-------------------------------------------------------------------------------------------
nvidia () {
    if lspci | grep -i nvidia > /dev/null; then
        echo "NVIDIA GPU detected."
        pkg_manager=$(get_package_manager)
        
        case $pkg_manager in
            nix)
                nix-env -iA nixos.linuxPackages.nvidia_x11
                ;;
            dnf)
                current_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n 1)
                latest_version=$(wget -qO- https://www.nvidia.com/Download/driverResults.aspx/170134/en-us | grep -oP 'Version:\s*\K\d+\.\d+')

                if [ "$current_version" == "$latest_version" ]; then
                    echo "Latest NVIDIA drivers are already installed."
                else

                    dnf install epel-release -y
                    dnf upgrade -y
                    dnf config-manager --add-repo http://developer.download.nvidia.com/compute/cuda/repos/rhel9/$(uname -i)/cuda-rhel9.repo -y
                    dnf install -y kernel-headers-$(uname -r) kernel-devel-$(uname -r) tar bzip2 make automake gcc gcc-c++ pciutils elfutils-libelf-devel libglvnd-opengl libglvnd-glx libglvnd-devel acpid pkgconfig dkms
                    dnf module install nvidia-driver:latest-dkms -y
                    echo "blacklist nouveau" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
                    echo 'omit_drivers+=" nouveau "' | sudo tee /etc/dracut.conf.d/blacklist-nouveau.conf
                    dracut --regenerate-all --force
                    depmod -a
                    dnf upgrade --refresh -y
                    dnf group install -y "Development tools"
                    lsmod | grep -i nvidia

                    dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm -y
                    dnf clean all
                    #site to get the instructions: https://developer.nvidia.com/cuda-downloads
                    wget https://developer.download.nvidia.com/compute/cuda/12.3.0/local_installers/cuda-repo-rhel9-12-3-local-12.3.0_545.23.06-1.x86_64.rpm
                    rpm -i cuda-repo-rhel9-12-3-local-12.3.0_545.23.06-1.x86_64.rpm
                    dnf clean all
                    dnf -y install cuda-toolkit-11-7
                fi
                ;;
            apt)
                apt-get update
                apt-get install -y nvidia-driver-latest nvidia-cuda-toolkit
                ;;
        esac
    else echo "No NVIDIA GPU detected."
    fi
}
#-------------------------------------------------------------------------------------------
rpms () {
    local common_packages=(
        "vim"
        "wget"
        "tmux"
        "unzip"
        "git"
    )

    local distro_specific_packages=()
    pkg_manager=$(get_package_manager)
    
    case $pkg_manager in
        nix)
            distro_specific_packages+=(
                "clevis"
                "ansible"
                "cifs-utils"
            )
            ;;
        dnf)
            distro_specific_packages+=(
                "kernel-devel"
                "dkms"
                "clevis-systemd"
                "ansible"
                "whois"
                "cifs-utils"
                "usbutils"
                "pciutils"
            )
            ;;
        apt)
            distro_specific_packages+=(
                "linux-headers-$(uname -r)"
                "dkms"
                "clevis"
                "ansible"
                "whois"
                "cifs-utils"
                "usbutils"
                "pciutils"
            )
            ;;
    esac

    update_system
    install_package "${common_packages[@]}" "${distro_specific_packages[@]}"
}
#-------------------------------------------------------------------------------------------
rmm () {
    DEBUG=0
    INSECURE=0
    NOMESH=0
    agentDL='https://agents.tacticalrmm.com/api/v2/agents/?version=2.5.0&arch=amd64&token=c3c119ef-cc60-4aab-9638-ca05cf5ec020&plat=linux&api=api.vtstools.com'
    meshDL='https://mesh.vtstools.com/meshagents?id=g02QAv0FP3rG8LSnKG7VPjsiTfNxbWw8J@@BTKbK0Pc0Zex9eWiznqv4aC92z41T&installflags=2&meshinstall=6'
    apiURL='https://api.vtstools.com'
    token='04fe17b8e8033b848fa6cad8c530b1b07dc65628e1f52ec55579bded75735e54'
    clientID='1'
    siteID='1'
    agentType='server'
    proxy=''
    agentBinPath='/usr/local/bin'
    binName='tacticalagent'
    agentBin="${agentBinPath}/${binName}"
    agentConf='/etc/tacticalagent'
    agentSvcName='tacticalagent.service'
    agentSysD="/etc/systemd/system/${agentSvcName}"
    meshDir='/opt/tacticalmesh'
    meshSystemBin="${meshDir}/meshagent"
    meshSvcName='meshagent.service'
    meshSysD="/lib/systemd/system/${meshSvcName}"
    deb=(ubuntu debian raspbian kali linuxmint)
    rhe=(fedora rocky centos rhel amzn arch opensuse)

    set_locale_deb() {
        locale-gen "en_US.UTF-8"
        localectl set-locale LANG=en_US.UTF-8
        . /etc/default/locale
    }

    set_locale_rhel() {
        localedef -c -i en_US -f UTF-8 en_US.UTF-8 >/dev/null 2>&1
        localectl set-locale LANG=en_US.UTF-8
        . /etc/locale.conf
    }

    RemoveOldAgent() {
        if [ -f "${agentSysD}" ]; 
        then
            systemctl disable ${agentSvcName}
            systemctl stop ${agentSvcName}
            rm -f ${agentSysD}
            systemctl daemon-reload
        fi
        if [ -f "${agentConf}" ]; 
        then rm -f ${agentConf} 
        fi
        if [ -f "${agentBin}" ]; 
        then rm -f ${agentBin} 
        fi
    }

    InstallMesh() {
        if [ -f /etc/os-release ]; then
            distroID=$(
                . /etc/os-release
                echo $ID
            )
            distroIDLIKE=$(
                . /etc/os-release
                echo $ID_LIKE
            )
            if [[ " ${deb[*]} " =~ " ${distroID} " ]]; 
                then set_locale_deb
            elif [[ " ${deb[*]} " =~ " ${distroIDLIKE} " ]]; 
                then set_locale_deb
            elif [[ " ${rhe[*]} " =~ " ${distroID} " ]]; 
                then set_locale_rhel
            else set_locale_rhel 
            fi
        fi
        meshTmpDir='/root/meshtemp'
        mkdir -p $meshTmpDir
        meshTmpBin="${meshTmpDir}/meshagent"
        wget --no-check-certificate -q -O ${meshTmpBin} ${meshDL}
        chmod +x ${meshTmpBin}
        mkdir -p ${meshDir}
        env LC_ALL=en_US.UTF-8 LANGUAGE=en_US XAUTHORITY=foo DISPLAY=bar ${meshTmpBin} -install --installPath=${meshDir}
        sleep 1
        rm -rf ${meshTmpDir}
    }

    RemoveMesh() {
        if [ -f "${meshSystemBin}" ]; then
            env XAUTHORITY=foo DISPLAY=bar ${meshSystemBin} -uninstall
            sleep 1
        fi
        if [ -f "${meshSysD}" ]; then
            systemctl stop ${meshSvcName} >/dev/null 2>&1
            systemctl disable ${meshSvcName} >/dev/null 2>&1
            rm -f ${meshSysD}
        fi
        rm -rf ${meshDir}
        systemctl daemon-reload
    }

    Uninstall() {
        RemoveMesh
        RemoveOldAgent
    }

    if [ $# -ne 0 ] && [ $1 == 'uninstall' ]; 
        then
            Uninstall
            exit 0
    fi

    while [[ "$#" -gt 0 ]]; do
        case $1 in
        --debug) DEBUG=1 ;;
        --insecure) INSECURE=1 ;;
        --nomesh) NOMESH=1 ;;
        *)
            echo "ERROR: Unknown parameter: $1"
            exit 1
            ;;
        esac
        shift
    done

    RemoveOldAgent

    echo "Downloading tactical agent..."
    wget -q -O ${agentBin} "${agentDL}"
    if [ $? -ne 0 ]; 
        then
        echo "ERROR: Unable to download tactical agent"
        exit 1
    fi
    chmod +x ${agentBin}

    MESH_NODE_ID=""

    if [[ $NOMESH -eq 1 ]]; then echo "Skipping mesh install"
    else
        if [ -f "${meshSystemBin}" ]; 
            then RemoveMesh 
        fi
        echo "Downloading and installing mesh agent..."
        InstallMesh
        sleep 2
        echo "Getting mesh node id..."
        MESH_NODE_ID=$(env XAUTHORITY=foo DISPLAY=bar ${agentBin} -m nixmeshnodeid)
    fi

    if [ ! -d "${agentBinPath}" ]; then
        echo "Creating ${agentBinPath}"
        mkdir -p ${agentBinPath}
    fi

    INSTALL_CMD="${agentBin} -m install -api ${apiURL} -client-id ${clientID} -site-id ${siteID} -agent-type ${agentType} -auth ${token}"
    if [ "${MESH_NODE_ID}" != '' ]; 
        then 
            INSTALL_CMD+=" --meshnodeid ${MESH_NODE_ID}" 
    fi
    if [[ $DEBUG -eq 1 ]]; 
        then 
            INSTALL_CMD+=" --log debug" 
    fi
    if [[ $INSECURE -eq 1 ]]; 
        then 
            INSTALL_CMD+=" --insecure" 
    fi
    if [ "${proxy}" != '' ]; 
        then 
            INSTALL_CMD+=" --proxy ${proxy}" 
    fi
    eval ${INSTALL_CMD}

    tacticalsvc="$(
        cat << EOF
[Unit]
Description=Tactical RMM Linux Agent

[Service]
Type=simple
ExecStart=${agentBin} -m svc
User=root
Group=root
Restart=always
RestartSec=5s
LimitNOFILE=1000000
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
)"
    echo "${tacticalsvc}" | tee ${agentSysD} >/dev/null
    systemctl daemon-reload
    systemctl enable ${agentSvcName}
    systemctl start ${agentSvcName}

    ## Logicmonitor
    ## n-able

}

#-------------------------------------------------------------------------------------------
postrun () {
    echo "########## vts-apol$OS_VERSION-bootstrap.sh: postrun"
    echo `date`
    # Remove the temp Puppet Boot Stuff
    rm -Rf /var/tmp/*
    #
    if [ "$POD" = "y" ] || [ "$POD" = "z" ] || [ "$POD" = "x" ] || [ "$ENTITY" = "infra" ] || [ "$ENV" = "cs" ]
    then
        echo "Clean up fragments of bootstrap puppet run"
        rm -Rfv /var/lib/puppet/ssl
        rm -Rfv /var/lib/puppet/yaml/*
        rm -Rfv /var/lib/puppet/state/*
        rm -Rfv /var/lib/puppet/clientbucket/*
        rm /etc/yum.repos.d/puppet5.repo
        echo "This Is A Infra Core build puppet.conf"
        #echo "Running Real Puppet"
        #puppetinfra
    else  
        echo "Clean up our mess for other Entity"
        dnf clean all
        rm -Rfv /etc/puppet
        rm -Rfv /var/lib/puppet
        rm -Rfv /etc/selinux/targeted/active/modules/100/puppet
        rm -Rfv /etc/logrotate.d/puppet
        rm -Rfv /var/log/puppet
        rm -Rfv /usr/share/logwatch/scripts/services/puppet
        rm /etc/yum.repos.d/puppet5.repo
        rm -rf /var/cache/yum
    fi
    #sed -i 's/umask 077/umask 022/g' /etc/profile
    #sed -i 's/umask 077/umask 022/g' /etc/bashrc
    return 0
}

#-------------------------------------------------------------------------------------------
markdone () {
    local hostname=$(hostname)
    local ip=$(hostname -i)
    local date=$(date)
    local subject="Bootstrap Complete: $hostname"
    local body="Bootstrap script completed successfully.

Host: $hostname
IP: $ip
Date: $date
Package Manager: $(get_package_manager)
"
    send_email "$subject" "$body"
    reboot
    rm -- "$0"
}
#-------------------------------------------------------------------------------------------
settime () {
    timedatectl set-timezone Europe/London

}
#-------------------------------------------------------------------------------------------
docker () {
    pkg_manager=$(get_package_manager)
    
    case $pkg_manager in
        nix)
            nix-env -iA nixpkgs.docker nixpkgs.docker-compose
            ;;
        dnf)
            dnf update -y
            dnf remove podman buildah -y
            dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            dnf install docker-ce docker-ce-cli containerd.io -y
            systemctl start docker
            systemctl status docker
            systemctl enable docker
            curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
            docker-compose --version
            docker --version
            if lspci | grep -i nvidia > /dev/null; then
                echo "NVIDIA GPU detected. Installing NVIDIA Docker..."
                distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
                curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.repo | sudo tee /etc/yum.repos.d/nvidia-docker.repo
                dnf install -y nvidia-docker2
                systemctl restart docker
                docker run --rm --gpus all nvidia/cuda:11.1.1-base-ubi8 nvidia-smi
            else
                echo "No NVIDIA GPU detected."
            fi
            ;;
        apt)
            apt-get update
            apt-get install -y ca-certificates curl gnupg
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
    esac

    systemctl start docker
    systemctl enable docker
}
#-------------------------------------------------------------------------------------------
llmama2() {
    pkg_manager=$(get_package_manager)
    
    case $pkg_manager in
        nix)
            nix-env -iA nixpkgs.python3Full \
                       nixpkgs.python3Packages.pip \
                       nixpkgs.git \
                       nixpkgs.cmake \
                       nixpkgs.gcc
            python3 -m pip install --user torch torchrun
            ;;
        dnf)
            dnf -y groupinstall development
            dnf install -y python3 python3-devel python3-pip cmake gcc gcc-c++ git
            python3 -m pip install --user torch torchrun
            ;;
        apt)
            apt-get update
            apt-get install -y python3 python3-dev python3-pip build-essential cmake git
            python3 -m pip install --user torch torchrun
            ;;
        *)
            echo "Unsupported package manager"
            return 1
            ;;
    esac

    LLAMA_DIR="/opt/llama2"
    mkdir -p "$LLAMA_DIR"
    cd "$LLAMA_DIR" || exit 1

    if [ ! -d "llama" ]; then
        git clone https://github.com/facebookresearch/llama.git
        cd llama || exit 1
        python3 -m pip install -e .
    fi

    if [ ! -d "llama-cpp-setup" ]; then
        git clone https://github.com/sychhq/llama-cpp-setup.git
        cd llama-cpp-setup || exit 1
        chmod +x setup.sh
    fi

#    echo "Llama2 setup completed. Please note:"
#    echo "1. You need to manually run './download.sh' in $LLAMA_DIR/llama after obtaining the download URL from Meta"
#    echo "2. To run the chat completion demo:"
#    echo "   cd $LLAMA_DIR/llama"
#    echo "   torchrun --nproc_per_node 1 example_chat_completion.py \\"
#    echo "     --ckpt_dir llama-2-7b-chat/ \\"
#    echo "     --tokenizer_path tokenizer.model \\"
#    echo "     --max_seq_len 512 \\"
#    echo "     --max_batch_size 6"
#    echo ""
#    echo "3. For llama.cpp setup:"
#    echo "   cd $LLAMA_DIR/llama-cpp-setup"
#    echo "   ./setup.sh"
}

#-------------------------------------------------------------------------------------------
do_all () {
    local log_file="/root/vts-bootstrap.log"
    touch $log_file
    
    {
        echo "Starting bootstrap process with package manager: $(get_package_manager)"
        echo "Date: $(date)"
        echo "System: $(uname -a)"
        
        for func in setupusers nvidia rpms rmm settime docker postrun; do
            echo "Running $func..."
            if ! $func; then
                echo "ERROR: $func failed"
                exit 1
            fi
        done
    } >> $log_file 2>&1
}

# Update case statement to use new argument parsing
if [ ! -z "$MODULE" ]; then
    case "$MODULE" in
        setupusers) setupusers ;;
        #nvidia) nvidia ;;
        rpms) rpms ;;
        rmm) rmm ;;
        postrun) postrun ;;
        settime) settime ;;
        #docker) docker ;;
        markdone) markdone ;;
        *) 
            echo "Invalid module: $MODULE"
            usage
            ;;
    esac
else
    do_all
fi

exit 0