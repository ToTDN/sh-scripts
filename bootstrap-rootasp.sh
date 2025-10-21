#!/usr/bin/env bash

set -e

# Bootstrap script for rootasp user setup
# Supports: Rocky Linux, Ubuntu, and NixOS

SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID5UbzwQP8PW/d/RSLa/tcFRha5cBtf/BZH4MY1paTJt"
USERNAME="rootasp"
SYSLOG_SERVER="xdr.vtstools.com"
SYSLOG_PORT="514"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_ID_LIKE="$ID_LIKE"
    else
        echo "ERROR: Cannot detect OS type"
        exit 1
    fi

    case "$OS_ID" in
        ubuntu|debian)
            OS_TYPE="debian"
            ;;
        rocky|rhel|centos|fedora|almalinux)
            OS_TYPE="rhel"
            ;;
        nixos)
            OS_TYPE="nixos"
            ;;
        *)
            # Check ID_LIKE for derivative distros
            case "$OS_ID_LIKE" in
                *debian*|*ubuntu*)
                    OS_TYPE="debian"
                    ;;
                *rhel*|*fedora*)
                    OS_TYPE="rhel"
                    ;;
                *)
                    echo "ERROR: Unsupported OS: $OS_ID"
                    exit 1
                    ;;
            esac
            ;;
    esac

    echo "Detected OS type: $OS_TYPE ($OS_ID)"
}

# Create user if not exists
create_user() {
    echo "Creating user: $USERNAME"

    if id "$USERNAME" &>/dev/null; then
        echo "User $USERNAME already exists, skipping creation"
    else
        if [ "$OS_TYPE" = "nixos" ]; then
            echo "WARNING: On NixOS, users should be configured in configuration.nix"
            echo "Creating user temporarily, but please add to configuration.nix"
            useradd -m -s /bin/bash "$USERNAME"
        else
            useradd -m -s /bin/bash "$USERNAME"
        fi
        echo "User $USERNAME created"
    fi
}

# Setup SSH key
setup_ssh() {
    echo "Setting up SSH key for $USERNAME"

    USER_HOME=$(eval echo ~$USERNAME)
    SSH_DIR="$USER_HOME/.ssh"
    AUTH_KEYS="$SSH_DIR/authorized_keys"

    mkdir -p "$SSH_DIR"

    if [ -f "$AUTH_KEYS" ]; then
        if grep -q "$SSH_KEY" "$AUTH_KEYS"; then
            echo "SSH key already exists in authorized_keys"
        else
            echo "$SSH_KEY" >> "$AUTH_KEYS"
            echo "SSH key added to authorized_keys"
        fi
    else
        echo "$SSH_KEY" > "$AUTH_KEYS"
        echo "SSH key added to authorized_keys"
    fi

    chmod 700 "$SSH_DIR"
    chmod 600 "$AUTH_KEYS"
    chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

    echo "SSH key setup completed"
}

# Configure sudo
configure_sudo() {
    echo "Configuring passwordless sudo for $USERNAME"

    SUDOERS_FILE="/etc/sudoers.d/$USERNAME"

    if [ "$OS_TYPE" = "nixos" ]; then
        echo "WARNING: On NixOS, sudo should be configured in configuration.nix"
        echo "Add the following to your configuration.nix:"
        echo "  security.sudo.extraRules = [{"
        echo "    users = [ \"$USERNAME\" ];"
        echo "    commands = [{ command = \"ALL\"; options = [ \"NOPASSWD\" ]; }];"
        echo "  }];"
        echo ""
        echo "Attempting to set up temporary sudoers file..."
    fi

    # Create sudoers file
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"

    # Validate sudoers file
    if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
        echo "Sudo configuration completed"
    else
        echo "ERROR: Invalid sudoers configuration"
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
}

# Configure syslog forwarding for Debian/Ubuntu
configure_syslog_debian() {
    echo "Configuring rsyslog to forward logs to $SYSLOG_SERVER..."

    # Install rsyslog if not present
    if ! command -v rsyslogd &>/dev/null; then
        echo "Installing rsyslog..."
        apt-get install -y rsyslog
    fi

    RSYSLOG_CONF="/etc/rsyslog.d/99-forward-to-xdr.conf"

    # Create rsyslog forwarding configuration
    cat > "$RSYSLOG_CONF" << EOF
# Forward all logs to XDR server
# Using TCP (@@) for reliable delivery
*.* @@${SYSLOG_SERVER}:${SYSLOG_PORT}

# Optional: Queue configuration for reliability
\$ActionQueueType LinkedList
\$ActionQueueFileName xdr_forward
\$ActionResumeRetryCount -1
\$ActionQueueSaveOnShutdown on
EOF

    echo "Rsyslog configuration created at $RSYSLOG_CONF"

    # Restart rsyslog service
    systemctl restart rsyslog
    systemctl enable rsyslog

    if systemctl is-active --quiet rsyslog; then
        echo "Rsyslog is running and forwarding logs to $SYSLOG_SERVER"
    else
        echo "WARNING: Rsyslog failed to start. Check logs with: journalctl -u rsyslog"
    fi
}

# Configure syslog forwarding for RHEL/Rocky
configure_syslog_rhel() {
    echo "Configuring rsyslog to forward logs to $SYSLOG_SERVER..."

    # Determine package manager
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi

    # Install rsyslog if not present
    if ! command -v rsyslogd &>/dev/null; then
        echo "Installing rsyslog..."
        $PKG_MGR install -y rsyslog
    fi

    RSYSLOG_CONF="/etc/rsyslog.d/99-forward-to-xdr.conf"

    # Create rsyslog forwarding configuration
    cat > "$RSYSLOG_CONF" << EOF
# Forward all logs to XDR server
# Using TCP (@@) for reliable delivery
*.* @@${SYSLOG_SERVER}:${SYSLOG_PORT}

# Optional: Queue configuration for reliability
\$ActionQueueType LinkedList
\$ActionQueueFileName xdr_forward
\$ActionResumeRetryCount -1
\$ActionQueueSaveOnShutdown on
EOF

    echo "Rsyslog configuration created at $RSYSLOG_CONF"

    # Restart rsyslog service
    systemctl restart rsyslog
    systemctl enable rsyslog

    if systemctl is-active --quiet rsyslog; then
        echo "Rsyslog is running and forwarding logs to $SYSLOG_SERVER"
    else
        echo "WARNING: Rsyslog failed to start. Check logs with: journalctl -u rsyslog"
    fi
}

# Configure syslog forwarding for NixOS
configure_syslog_nixos() {
    echo "Configuring syslog forwarding for NixOS..."

    echo "WARNING: NixOS requires declarative configuration in configuration.nix"
    echo "Please add the following to your configuration.nix:"
    echo ""
    echo "  services.rsyslog = {"
    echo "    enable = true;"
    echo "    extraConfig = ''"
    echo "      # Forward all logs to XDR server"
    echo "      *.* @@${SYSLOG_SERVER}:${SYSLOG_PORT}"
    echo ""
    echo "      # Queue configuration for reliability"
    echo "      \\\$ActionQueueType LinkedList"
    echo "      \\\$ActionQueueFileName xdr_forward"
    echo "      \\\$ActionResumeRetryCount -1"
    echo "      \\\$ActionQueueSaveOnShutdown on"
    echo "    '';"
    echo "  };"
    echo ""
    echo "Then rebuild your system with: nixos-rebuild switch"
    echo ""
}

# Configure syslog based on OS type
configure_syslog() {
    case "$OS_TYPE" in
        debian)
            configure_syslog_debian
            ;;
        rhel)
            configure_syslog_rhel
            ;;
        nixos)
            configure_syslog_nixos
            ;;
        *)
            echo "ERROR: Unknown OS type for syslog configuration"
            exit 1
            ;;
    esac
}

# Detect GPU
detect_gpu() {
    echo "Detecting GPU hardware..."

    # Install lspci if not available
    if ! command -v lspci &>/dev/null; then
        if [ "$OS_TYPE" = "debian" ]; then
            apt-get install -y pciutils
        elif [ "$OS_TYPE" = "rhel" ]; then
            if command -v dnf &>/dev/null; then
                dnf install -y pciutils
            else
                yum install -y pciutils
            fi
        fi
    fi

    GPU_TYPE="none"
    GPU_DETECTED=0

    # Check for NVIDIA GPU
    if lspci | grep -i nvidia | grep -iq "vga\|3d\|display"; then
        GPU_TYPE="nvidia"
        GPU_DETECTED=1
        GPU_MODEL=$(lspci | grep -i nvidia | grep -i "vga\|3d\|display" | head -n1)
        echo "NVIDIA GPU detected: $GPU_MODEL"
    # Check for AMD GPU
    elif lspci | grep -i amd | grep -iq "vga\|3d\|display"; then
        GPU_TYPE="amd"
        GPU_DETECTED=1
        GPU_MODEL=$(lspci | grep -i amd | grep -i "vga\|3d\|display" | head -n1)
        echo "AMD GPU detected: $GPU_MODEL"
    # Check for Intel GPU
    elif lspci | grep -i intel | grep -iq "vga\|3d\|display"; then
        GPU_TYPE="intel"
        GPU_DETECTED=1
        GPU_MODEL=$(lspci | grep -i intel | grep -i "vga\|3d\|display" | head -n1)
        echo "Intel GPU detected: $GPU_MODEL"
    else
        echo "No dedicated GPU detected, skipping driver installation"
    fi

    export GPU_TYPE
    export GPU_DETECTED
}

# Install NVIDIA drivers for Debian/Ubuntu
install_nvidia_drivers_debian() {
    echo "Installing NVIDIA drivers for Debian/Ubuntu..."

    export DEBIAN_FRONTEND=noninteractive

    # Add required repositories
    apt-get update
    apt-get install -y software-properties-common

    # Install NVIDIA drivers
    echo "Installing NVIDIA proprietary drivers..."
    apt-get install -y nvidia-driver nvidia-utils || {
        echo "Trying alternative NVIDIA driver installation..."
        ubuntu-drivers devices 2>/dev/null && ubuntu-drivers autoinstall || {
            echo "WARNING: Automatic NVIDIA driver installation failed"
            echo "You may need to install drivers manually"
        }
    }

    # Install CUDA toolkit (optional but useful for GPU workloads)
    echo "Installing NVIDIA CUDA toolkit..."
    apt-get install -y nvidia-cuda-toolkit || echo "CUDA toolkit installation skipped"

    echo "NVIDIA driver installation completed. A reboot may be required."
}

# Install NVIDIA drivers for RHEL/Rocky
install_nvidia_drivers_rhel() {
    echo "Installing NVIDIA drivers for RHEL/Rocky..."

    # Determine package manager
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi

    # Install required repositories
    $PKG_MGR install -y epel-release || true

    # Add NVIDIA repository
    $PKG_MGR config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel$(rpm -E %{rhel})/x86_64/cuda-rhel$(rpm -E %{rhel}).repo 2>/dev/null || {
        echo "Adding NVIDIA repository manually..."
        RHEL_VERSION=$(rpm -E %{rhel})
        cat > /etc/yum.repos.d/cuda.repo << EOF
[cuda]
name=cuda
baseurl=https://developer.download.nvidia.com/compute/cuda/repos/rhel${RHEL_VERSION}/x86_64/
enabled=1
gpgcheck=1
gpgkey=https://developer.download.nvidia.com/compute/cuda/repos/rhel${RHEL_VERSION}/x86_64/D42D0685.pub
EOF
    }

    # Install NVIDIA drivers
    echo "Installing NVIDIA drivers and tools..."
    $PKG_MGR install -y kernel-devel kernel-headers gcc make dkms acpid libglvnd-glx libglvnd-opengl libglvnd-devel pkgconfig

    # Install NVIDIA driver
    $PKG_MGR module install nvidia-driver:latest-dkms || {
        $PKG_MGR install -y nvidia-driver nvidia-driver-cuda || {
            echo "WARNING: Automatic NVIDIA driver installation failed"
            echo "You may need to install drivers manually"
        }
    }

    echo "NVIDIA driver installation completed. A reboot may be required."
}

# Install AMD drivers for Debian/Ubuntu
install_amd_drivers_debian() {
    echo "Installing AMD drivers for Debian/Ubuntu..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    # Install Mesa drivers (open-source AMD drivers)
    echo "Installing Mesa/AMDGPU drivers..."
    apt-get install -y mesa-vulkan-drivers mesa-va-drivers mesa-vdpau-drivers
    apt-get install -y xserver-xorg-video-amdgpu || echo "AMDGPU xorg driver skipped"

    # Install firmware
    apt-get install -y firmware-amd-graphics || apt-get install -y linux-firmware

    # Install ROCm for compute workloads (optional)
    echo "Checking for ROCm availability..."
    apt-get install -y rocm-hip-runtime rocm-opencl-runtime || echo "ROCm installation skipped"

    echo "AMD driver installation completed. A reboot may be required."
}

# Install AMD drivers for RHEL/Rocky
install_amd_drivers_rhel() {
    echo "Installing AMD drivers for RHEL/Rocky..."

    # Determine package manager
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi

    # Install Mesa drivers
    echo "Installing Mesa/AMDGPU drivers..."
    $PKG_MGR install -y mesa-dri-drivers mesa-vulkan-drivers
    $PKG_MGR install -y xorg-x11-drv-amdgpu || echo "AMDGPU xorg driver skipped"

    # Install firmware
    $PKG_MGR install -y linux-firmware

    echo "AMD driver installation completed. A reboot may be required."
}

# Install Intel drivers for Debian/Ubuntu
install_intel_drivers_debian() {
    echo "Installing Intel GPU drivers for Debian/Ubuntu..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    # Install Intel drivers (usually included by default but ensure they're present)
    echo "Installing Intel graphics drivers..."
    apt-get install -y intel-media-va-driver i965-va-driver mesa-vulkan-drivers
    apt-get install -y xserver-xorg-video-intel || echo "Intel xorg driver skipped (may use modesetting)"

    # Install Intel compute runtime for GPU compute
    apt-get install -y intel-opencl-icd || echo "Intel OpenCL runtime skipped"

    echo "Intel driver installation completed."
}

# Install Intel drivers for RHEL/Rocky
install_intel_drivers_rhel() {
    echo "Installing Intel GPU drivers for RHEL/Rocky..."

    # Determine package manager
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi

    # Install Intel drivers
    echo "Installing Intel graphics drivers..."
    $PKG_MGR install -y mesa-dri-drivers mesa-vulkan-drivers
    $PKG_MGR install -y xorg-x11-drv-intel || echo "Intel xorg driver skipped"
    $PKG_MGR install -y libva-intel-driver intel-mediasdk || echo "Intel media drivers skipped"

    echo "Intel driver installation completed."
}

# Install GPU drivers for NixOS
install_gpu_drivers_nixos() {
    echo "Configuring GPU drivers for NixOS..."

    echo "WARNING: NixOS requires declarative configuration in configuration.nix"
    echo "Please add the following to your configuration.nix based on your GPU:"
    echo ""

    if [ "$GPU_TYPE" = "nvidia" ]; then
        echo "  # NVIDIA GPU Configuration"
        echo "  services.xserver.videoDrivers = [ \"nvidia\" ];"
        echo "  hardware.nvidia = {"
        echo "    modesetting.enable = true;"
        echo "    powerManagement.enable = false;"
        echo "    open = false;  # Use proprietary driver"
        echo "    nvidiaSettings = true;"
        echo "  };"
        echo "  # Optional: Enable CUDA"
        echo "  # nixpkgs.config.allowUnfree = true;"
        echo "  # environment.systemPackages = with pkgs; [ cudatoolkit ];"
    elif [ "$GPU_TYPE" = "amd" ]; then
        echo "  # AMD GPU Configuration"
        echo "  services.xserver.videoDrivers = [ \"amdgpu\" ];"
        echo "  hardware.opengl = {"
        echo "    enable = true;"
        echo "    driSupport = true;"
        echo "    driSupport32Bit = true;"
        echo "  };"
        echo "  # Optional: Enable ROCm for compute"
        echo "  # hardware.opengl.extraPackages = with pkgs; [ rocm-opencl-icd ];"
    elif [ "$GPU_TYPE" = "intel" ]; then
        echo "  # Intel GPU Configuration"
        echo "  services.xserver.videoDrivers = [ \"intel\" ];"
        echo "  hardware.opengl = {"
        echo "    enable = true;"
        echo "    driSupport = true;"
        echo "    extraPackages = with pkgs; ["
        echo "      intel-media-driver"
        echo "      vaapiIntel"
        echo "      vaapiVdpau"
        echo "      libvdpau-va-gl"
        echo "    ];"
        echo "  };"
    fi

    echo ""
    echo "Then rebuild your system with: nixos-rebuild switch"
    echo ""
}

# Install GPU drivers based on detection
install_gpu_drivers() {
    if [ "$GPU_DETECTED" -eq 0 ]; then
        echo "No GPU detected, skipping driver installation"
        return 0
    fi

    echo "Installing drivers for $GPU_TYPE GPU..."

    case "$OS_TYPE" in
        debian)
            case "$GPU_TYPE" in
                nvidia)
                    install_nvidia_drivers_debian
                    ;;
                amd)
                    install_amd_drivers_debian
                    ;;
                intel)
                    install_intel_drivers_debian
                    ;;
            esac
            ;;
        rhel)
            case "$GPU_TYPE" in
                nvidia)
                    install_nvidia_drivers_rhel
                    ;;
                amd)
                    install_amd_drivers_rhel
                    ;;
                intel)
                    install_intel_drivers_rhel
                    ;;
            esac
            ;;
        nixos)
            install_gpu_drivers_nixos
            ;;
        *)
            echo "ERROR: Unknown OS type for GPU driver installation"
            return 1
            ;;
    esac

    echo "GPU driver installation completed"
}

# Install packages for Debian/Ubuntu
install_packages_debian() {
    echo "Installing packages for Debian/Ubuntu..."

    export DEBIAN_FRONTEND=noninteractive

    # Update package lists
    apt-get update

    # Install neovim
    echo "Installing neovim..."
    apt-get install -y neovim

    # Install neofetch
    echo "Installing neofetch..."
    apt-get install -y neofetch

    # Install mainline kernel (latest available)
    echo "Installing mainline kernel..."
    apt-get install -y linux-generic || apt-get install -y linux-image-generic

    # Install oh-my-posh
    echo "Installing oh-my-posh..."
    wget -q https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/posh-linux-amd64 -O /usr/local/bin/oh-my-posh
    chmod +x /usr/local/bin/oh-my-posh

    # Install required dependencies for TacticalRMM
    apt-get install -y wget curl systemd

    echo "Package installation completed for Debian/Ubuntu"
}

# Install packages for RHEL/Rocky
install_packages_rhel() {
    echo "Installing packages for RHEL/Rocky..."

    # Determine package manager
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi

    # Install EPEL repository if needed
    $PKG_MGR install -y epel-release || true

    # Install neovim
    echo "Installing neovim..."
    $PKG_MGR install -y neovim

    # Install neofetch
    echo "Installing neofetch..."
    $PKG_MGR install -y neofetch

    # Install mainline kernel
    echo "Installing mainline kernel..."
    $PKG_MGR install -y kernel kernel-devel

    # Install oh-my-posh
    echo "Installing oh-my-posh..."
    wget -q https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/posh-linux-amd64 -O /usr/local/bin/oh-my-posh
    chmod +x /usr/local/bin/oh-my-posh

    # Install required dependencies for TacticalRMM
    $PKG_MGR install -y wget curl systemd

    echo "Package installation completed for RHEL/Rocky"
}

# Install packages for NixOS
install_packages_nixos() {
    echo "Installing packages for NixOS..."

    echo "WARNING: NixOS requires declarative configuration in configuration.nix"
    echo "Please add the following packages to your configuration.nix:"
    echo "  environment.systemPackages = with pkgs; ["
    echo "    neovim"
    echo "    neofetch"
    echo "    linuxPackages_latest.kernel"
    echo "    oh-my-posh"
    echo "  ];"
    echo ""
    echo "Attempting to install packages imperatively (temporary)..."

    # Try to install packages using nix-env
    nix-env -iA nixos.neovim nixos.neofetch nixos.oh-my-posh || {
        echo "WARNING: Some packages may not be available via nix-env"
        echo "Please use configuration.nix for proper NixOS setup"
    }

    echo "Package installation attempted for NixOS"
}

# Install packages based on OS
install_packages() {
    case "$OS_TYPE" in
        debian)
            install_packages_debian
            ;;
        rhel)
            install_packages_rhel
            ;;
        nixos)
            install_packages_nixos
            ;;
        *)
            echo "ERROR: Unknown OS type for package installation"
            exit 1
            ;;
    esac
}

# Install TacticalRMM
install_tacticalrmm() {
    echo "Installing TacticalRMM..."

    if [ "$OS_TYPE" = "nixos" ]; then
        echo "WARNING: TacticalRMM installation on NixOS may require additional configuration"
        echo "Proceeding with installation attempt..."
    fi

    # Create temporary file for TacticalRMM installer
    TRMM_INSTALLER="/tmp/tacticalrmm-install.sh"

    cat > "$TRMM_INSTALLER" << 'EOFTRMM'
#!/usr/bin/env bash

if [ $EUID -ne 0 ]; then
    echo "ERROR: Must be run as root"
    exit 1
fi

HAS_SYSTEMD=$(ps --no-headers -o comm 1)
if [ "${HAS_SYSTEMD}" != 'systemd' ]; then
    echo "This install script only supports systemd"
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

DEBUG=0
INSECURE=0
NOMESH=0

agentDL='https://agents.tacticalrmm.com/api/v2/agents/?version=2.9.1&arch=amd64&token=c3c119ef-cc60-4aab-9638-ca05cf5ec020&plat=linux&api=api.vtstools.com'
meshDL='https://mesh.vtstools.com/meshagents?id=g02QAv0FP3rG8LSnKG7VPjsiTfNxbWw8J@@BTKbK0Pc0Zex9eWiznqv4aC92z41T&installflags=2&meshinstall=6'

apiURL='https://api.vtstools.com'
token='4524150047ecb77c211b731e55034b40dad677fbc2a0a7b68e9982ae0f8bb73d'
clientID='14'
siteID='24'
agentType='server'
proxy=''

agentBinPath='/usr/local/bin'
binName='tacticalagent'
agentBin="${agentBinPath}/${binName}"
agentConf='/etc/tacticalagent'
agentSvcName='tacticalagent.service'
agentSysD="/etc/systemd/system/${agentSvcName}"
agentDir='/opt/tacticalagent'
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
    if [ -f "${agentSysD}" ]; then
        systemctl disable ${agentSvcName}
        systemctl stop ${agentSvcName}
        rm -f "${agentSysD}"
        systemctl daemon-reload
    fi

    if [ -f "${agentConf}" ]; then
        rm -f "${agentConf}"
    fi

    if [ -f "${agentBin}" ]; then
        rm -f "${agentBin}"
    fi

    if [ -d "${agentDir}" ]; then
        rm -rf "${agentDir}"
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
        if [[ " ${deb[*]} " =~ " ${distroID} " ]]; then
            set_locale_deb
        elif [[ " ${deb[*]} " =~ " ${distroIDLIKE} " ]]; then
            set_locale_deb
        elif [[ " ${rhe[*]} " =~ " ${distroID} " ]]; then
            set_locale_rhel
        else
            set_locale_rhel
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

if [ $# -ne 0 ] && [[ $1 =~ ^(uninstall|-uninstall|--uninstall)$ ]]; then
    Uninstall
    # Remove the current script
    rm "$0"
    exit 0
fi

while [[ "$#" -gt 0 ]]; do
    case $1 in
    -debug | --debug | debug) DEBUG=1 ;;
    -insecure | --insecure | insecure) INSECURE=1 ;;
    -nomesh | --nomesh | nomesh) NOMESH=1 ;;
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
if [ $? -ne 0 ]; then
    echo "ERROR: Unable to download tactical agent"
    exit 1
fi
chmod +x ${agentBin}

MESH_NODE_ID=""

if [[ $NOMESH -eq 1 ]]; then
    echo "Skipping mesh install"
else
    if [ -f "${meshSystemBin}" ]; then
        RemoveMesh
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

if [ "${MESH_NODE_ID}" != '' ]; then
    INSTALL_CMD+=" --meshnodeid ${MESH_NODE_ID}"
fi

if [[ $DEBUG -eq 1 ]]; then
    INSTALL_CMD+=" --log debug"
fi

if [[ $INSECURE -eq 1 ]]; then
    INSTALL_CMD+=" --insecure"
fi

if [ "${proxy}" != '' ]; then
    INSTALL_CMD+=" --proxy ${proxy}"
fi

eval ${INSTALL_CMD}

tacticalsvc="$(
    cat <<EOF
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
EOFTRMM

    chmod +x "$TRMM_INSTALLER"

    # Unset DISPLAY variable if set to avoid TacticalRMM installer error
    unset DISPLAY

    # Run the installer
    bash "$TRMM_INSTALLER"

    # Clean up
    rm -f "$TRMM_INSTALLER"

    echo "TacticalRMM installation completed"
}

# Main execution
main() {
    echo "Starting bootstrap for user: $USERNAME"
    echo "=========================================="

    detect_os
    create_user
    setup_ssh
    configure_sudo
    configure_syslog
    detect_gpu
    install_gpu_drivers
    install_packages
    install_tacticalrmm

    echo "=========================================="
    echo "Bootstrap completed successfully!"
    echo ""
    echo "User: $USERNAME"
    echo "SSH key has been configured"
    echo "Passwordless sudo has been enabled"
    echo "Syslog forwarding configured to: $SYSLOG_SERVER:$SYSLOG_PORT"

    if [ "$GPU_DETECTED" -eq 1 ]; then
        echo "GPU detected: $GPU_TYPE"
        echo "GPU drivers have been installed (reboot may be required)"
    else
        echo "No dedicated GPU detected"
    fi

    echo "Packages installed: neovim, neofetch, mainline kernel, oh-my-posh"
    echo "TacticalRMM has been installed"
    echo ""
    echo "You can now SSH in as: $USERNAME"

    if [ "$OS_TYPE" = "nixos" ]; then
        echo ""
        echo "IMPORTANT: On NixOS, please add the user configuration to /etc/nixos/configuration.nix"
        echo "for persistent configuration across rebuilds."
    fi
}

main "$@"
