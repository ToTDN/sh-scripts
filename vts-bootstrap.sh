#!/bin/sh
# Vitalytics Linux Bootstrap - Cross-Distribution Compatible
# Supports: Ubuntu, Rocky Linux, RHEL, NixOS
# Features: 
#   - Multi-vendor GPU driver installation (NVIDIA, AMD, Intel)
#   - Workstation vs Server detection
#   - Devolutions Remote Desktop Manager (workstations only)
#   - Docker, RMM agent, user management, and more

set -eu

# Global variables
SCRIPT_VERSION="2.0.0"
LOG_FILE="/var/log/vts-bootstrap.log"
NIXOS_CONFIG="/etc/nixos/configuration.nix"
NIXOS_BACKUP="/etc/nixos/configuration.nix.backup"

# Initialize logging
init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    exec 1> >(tee -a "$LOG_FILE")
    exec 2>&1
    echo "=== Bootstrap started at $(date) ==="
}

# Detect distribution using /etc/os-release
detect_distribution() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

# Improved package manager detection
get_package_manager() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|raspbian|linuxmint)
                echo "apt"
                ;;
            rhel|centos|rocky|fedora|almalinux|ol)
                if command -v dnf >/dev/null 2>&1; then
                    echo "dnf"
                else
                    echo "yum"
                fi
                ;;
            nixos)
                echo "nix"
                ;;
            *)
                # Fallback detection
                if command -v apt-get >/dev/null 2>&1; then
                    echo "apt"
                elif command -v dnf >/dev/null 2>&1; then
                    echo "dnf"
                elif command -v yum >/dev/null 2>&1; then
                    echo "yum"
                elif command -v nix-env >/dev/null 2>&1; then
                    echo "nix"
                else
                    echo "unknown"
                fi
                ;;
        esac
    else
        # Legacy fallback
        if command -v apt-get >/dev/null 2>&1; then
            echo "apt"
        elif command -v dnf >/dev/null 2>&1; then
            echo "dnf"
        elif command -v yum >/dev/null 2>&1; then
            echo "yum"
        elif command -v nix-env >/dev/null 2>&1; then
            echo "nix"
        else
            echo "unknown"
        fi
    fi
}

# Wait for package manager locks
wait_for_package_manager() {
    local pkg_manager="$1"
    local max_wait=300
    local waited=0
    
    case "$pkg_manager" in
        apt)
            while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
                  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
                  fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
                if [ "$waited" -ge "$max_wait" ]; then
                    echo "ERROR: Package manager lock timeout"
                    return 1
                fi
                echo "Waiting for package manager lock..."
                sleep 5
                waited=$((waited + 5))
            done
            ;;
        dnf|yum)
            while pgrep -x dnf >/dev/null 2>&1 || pgrep -x yum >/dev/null 2>&1; do
                if [ "$waited" -ge "$max_wait" ]; then
                    echo "ERROR: Package manager lock timeout"
                    return 1
                fi
                echo "Waiting for package manager lock..."
                sleep 5
                waited=$((waited + 5))
            done
            ;;
        nix)
            while [ -f /nix/var/nix/db/big-lock ]; do
                if [ "$waited" -ge "$max_wait" ]; then
                    echo "ERROR: Nix lock timeout"
                    return 1
                fi
                echo "Waiting for Nix lock..."
                sleep 5
                waited=$((waited + 5))
            done
            ;;
    esac
}

# Find executable in common paths
find_executable() {
    local cmd="$1"
    local paths="/run/current-system/sw/bin /usr/bin /bin /usr/local/bin /sbin /usr/sbin"
    
    for path in $paths; do
        if [ -x "$path/$cmd" ]; then
            echo "$path/$cmd"
            return 0
        fi
    done
    
    command -v "$cmd" 2>/dev/null || return 1
}

# Unified package installation
install_package() {
    local pkg_manager
    pkg_manager=$(get_package_manager)
    
    if [ "$pkg_manager" = "unknown" ]; then
        echo "ERROR: Unknown package manager"
        return 1
    fi
    
    wait_for_package_manager "$pkg_manager"
    
    case "$pkg_manager" in
        apt)
            apt-get update -qq
            apt-get install -y "$@"
            ;;
        dnf)
            dnf install -y "$@"
            ;;
        yum)
            yum install -y "$@"
            ;;
        nix)
            # For NixOS, we'll need to handle this differently
            echo "Note: Package installation on NixOS requires configuration changes"
            for pkg in "$@"; do
                if ! command -v "$pkg" >/dev/null 2>&1; then
                    nix-env -iA "nixpkgs.$pkg" || echo "Warning: Failed to install $pkg"
                fi
            done
            ;;
    esac
}

# Update system packages
update_system() {
    local pkg_manager
    pkg_manager=$(get_package_manager)
    
    wait_for_package_manager "$pkg_manager"
    
    case "$pkg_manager" in
        apt)
            apt-get update -qq && apt-get upgrade -y
            ;;
        dnf)
            dnf update -y
            ;;
        yum)
            yum update -y
            ;;
        nix)
            nix-channel --update
            nix-env -u '*'
            ;;
    esac
}

# Package name mapping
map_package_names() {
    local pkg="$1"
    local distro
    distro=$(detect_distribution)
    
    case "$pkg:$distro" in
        build-essential:ubuntu|build-essential:debian)
            echo "build-essential"
            ;;
        build-essential:rhel|build-essential:rocky|build-essential:centos)
            echo "@development-tools"
            ;;
        build-essential:nixos)
            echo "stdenv"
            ;;
        g++:ubuntu|g++:debian)
            echo "g++"
            ;;
        g++:rhel|g++:rocky|g++:centos)
            echo "gcc-c++"
            ;;
        g++:nixos)
            echo "gcc"
            ;;
        libssl-dev:ubuntu|libssl-dev:debian)
            echo "libssl-dev"
            ;;
        libssl-dev:rhel|libssl-dev:rocky|libssl-dev:centos)
            echo "openssl-devel"
            ;;
        libssl-dev:nixos)
            echo "openssl"
            ;;
        net-tools:nixos)
            echo "nettools"
            ;;
        *)
            echo "$pkg"
            ;;
    esac
}

# Usage function
usage() {
    cat << EOF
Usage: $0 -p <password> [-m <module>] [-h]

Options:
  -p <password>  Required: Password for SMTP relay and user setup
  -m <module>    Optional: Run specific module only
                 Modules: setupusers, gpu, packages, rmm, rdm, postrun, 
                         settime, docker, markdone, all
  -h             Show this help message

Modules:
  setupusers  - Create users and configure sudo access
  gpu         - Detect and install GPU drivers (NVIDIA/AMD/Intel)
  packages    - Install system packages
  rmm         - Install Remote Monitoring & Management agent
  rdm         - Install Devolutions Remote Desktop Manager (workstations only)
  postrun     - Cleanup and optimization
  settime     - Configure timezone
  docker      - Install Docker
  markdone    - Send completion notification and reboot

Examples:
  $0 -p "mypassword"              # Run all modules
  $0 -p "mypassword" -m docker    # Run only docker module
  $0 -p "mypassword" -m gpu       # Install GPU drivers only

EOF
    exit 1
}

# Parse arguments
SMTP_PASSWORD=""
MODULE="all"

while getopts ":p:m:h" opt; do
    case ${opt} in
        p)
            SMTP_PASSWORD="$OPTARG"
            ;;
        m)
            MODULE="$OPTARG"
            ;;
        h)
            usage
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            echo "Option -$OPTARG requires an argument" >&2
            usage
            ;;
    esac
done

if [ -z "$SMTP_PASSWORD" ]; then
    echo "ERROR: Password is required"
    usage
fi

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Check for systemd (except on NixOS which handles services differently)
check_systemd() {
    local distro
    distro=$(detect_distribution)
    
    if [ "$distro" != "nixos" ]; then
        if ! command -v systemctl >/dev/null 2>&1; then
            echo "ERROR: systemd is required but not found"
            return 1
        fi
        
        if ! systemctl --version >/dev/null 2>&1; then
            echo "ERROR: systemd is not functioning properly"
            return 1
        fi
    fi
    return 0
}

# Setup system information
setup_system_info() {
    HOSTNAME=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
    FQDN=$(hostname -f 2>/dev/null || hostname)
    
    # Get IP more reliably
    if command -v ip >/dev/null 2>&1; then
        IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}')
    else
        IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    fi
    
    # Parse hostname components
    DC=$(echo "${HOSTNAME}" | cut -c1-2)
    ROLE=$(echo "${HOSTNAME}" | cut -c5-6)
    ENV=$(echo "${HOSTNAME}" | cut -c3-4)
    XY=$(echo "${HOSTNAME}" | cut -c7-8)
    YZ=$(echo "${HOSTNAME}" | cut -c8-9)
    POD=$(echo "${HOSTNAME}" | cut -c7)
    MREPO="${DC}${POD}mrepo"
    LPOD="${DC}${POD}"
    ENTITY="${YZ}"
    OS=$(echo "${HOSTNAME}" | cut -c10)
    
    # Detect system manufacturer
    if command -v dmidecode >/dev/null 2>&1; then
        DMI=$(dmidecode -s system-manufacturer 2>/dev/null || echo "Unknown")
    else
        DMI="Unknown"
    fi
    
    # Get OS version
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_VERSION="$VERSION_ID"
    else
        OS_VERSION="Unknown"
    fi
}

# Send email notification
send_email() {
    local subject="$1"
    local body="$2"
    local smtp_server="smtp.office365.com"
    local smtp_port="587"
    local smtp_user="SMTP_relay@vitalytics.co.uk"
    local recipient="support@vitalytics.co.uk"
    
    # Install mail client if needed
    if ! command -v s-nail >/dev/null 2>&1 && ! command -v mail >/dev/null 2>&1; then
        echo "Installing mail client..."
        case $(detect_distribution) in
            ubuntu|debian)
                install_package s-nail
                ;;
            rhel|rocky|centos)
                install_package s-nail || install_package mailx
                ;;
            nixos)
                nix-env -iA nixpkgs.s-nail
                ;;
        esac
    fi
    
    # Create temporary mail config
    local mailrc_tmp="/tmp/.mailrc.$$"
    cat > "$mailrc_tmp" << EOF
set smtp=$smtp_server:$smtp_port
set smtp-use-starttls
set smtp-auth=login
set smtp-auth-user=$smtp_user
set smtp-auth-password=$SMTP_PASSWORD
set ssl-verify=ignore
set nss-config-dir=/etc/pki/nssdb/
EOF
    chmod 600 "$mailrc_tmp"
    
    # Send email
    if command -v s-nail >/dev/null 2>&1; then
        echo "$body" | MAILRC="$mailrc_tmp" s-nail -s "$subject" -r "$smtp_user" "$recipient"
    elif command -v mail >/dev/null 2>&1; then
        echo "$body" | MAILRC="$mailrc_tmp" mail -s "$subject" -r "$smtp_user" "$recipient"
    else
        echo "Warning: No mail client available to send notification"
    fi
    
    rm -f "$mailrc_tmp"
}

# Setup users
setupusers() {
    echo "Setting up users..."
    local distro
    distro=$(detect_distribution)
    
    if [ "$distro" = "nixos" ]; then
        # Check if mutable users are enabled
        if grep -q "users.mutableUsers = false" "$NIXOS_CONFIG" 2>/dev/null; then
            echo "NixOS has immutable users. Adding user configuration to $NIXOS_CONFIG"
            
            # Backup configuration
            cp "$NIXOS_CONFIG" "$NIXOS_BACKUP"
            
            # Generate password hash
            local password_hash
            if command -v mkpasswd >/dev/null 2>&1; then
                password_hash=$(echo "$SMTP_PASSWORD" | mkpasswd -m sha-512 -s)
            else
                echo "Warning: mkpasswd not found. User will need to set password manually."
                password_hash=""
            fi
            
            # Add user configuration
            cat >> "$NIXOS_CONFIG" << EOF

# Added by vts-bootstrap
users.users.rootasp = {
  isNormalUser = true;
  extraGroups = [ "wheel" ];
  hashedPassword = "$password_hash";
};
EOF
            
            echo "User configuration added. Run 'nixos-rebuild switch' to apply."
            return 0
        fi
    fi
    
    # Traditional user creation
    if id "rootasp" >/dev/null 2>&1; then
        echo "User 'rootasp' already exists. Updating password..."
        echo "rootasp:$SMTP_PASSWORD" | chpasswd
    else
        # Create user
        if command -v adduser >/dev/null 2>&1 && [ "$distro" = "ubuntu" -o "$distro" = "debian" ]; then
            adduser --disabled-password --gecos "" rootasp
        else
            useradd -m rootasp
        fi
        
        # Set password
        echo "rootasp:$SMTP_PASSWORD" | chpasswd
        
        if id "rootasp" >/dev/null 2>&1; then
            echo "User 'rootasp' created successfully."
        else
            echo "Failed to create user 'rootasp'."
            return 1
        fi
    fi
    
    # Configure sudo
    local sudo_group
    case "$distro" in
        ubuntu|debian)
            sudo_group="sudo"
            ;;
        *)
            sudo_group="wheel"
            ;;
    esac
    
    # Add user to sudo group
    if command -v usermod >/dev/null 2>&1; then
        usermod -aG "$sudo_group" rootasp
    fi
    
    # Add sudoers entry
    echo "rootasp ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/rootasp
    chmod 440 /etc/sudoers.d/rootasp
    
    echo "User setup completed."
}

# Detect GPU vendor
detect_gpu_vendor() {
    # Check if lspci is available
    if ! command -v lspci >/dev/null 2>&1; then
        echo "Unknown"
        return
    fi
    
    local gpu_info
    gpu_info=$(lspci -nn 2>/dev/null | grep -E 'VGA|3D|Display' || echo "")
    
    if echo "$gpu_info" | grep -q '\[10de:'; then
        echo "NVIDIA"
    elif echo "$gpu_info" | grep -q '\[1002:'; then
        echo "AMD"
    elif echo "$gpu_info" | grep -q '\[8086:'; then
        echo "Intel"
    else
        echo "Unknown"
    fi
}

# Detect if system is workstation or server
detect_system_type() {
    local workstation_indicators=0
    local server_indicators=0
    
    # Check systemd default target
    if command -v systemctl >/dev/null 2>&1; then
        local default_target
        default_target=$(systemctl get-default 2>/dev/null || echo "")
        case "$default_target" in
            graphical.target) workstation_indicators=$((workstation_indicators + 1)) ;;
            multi-user.target) server_indicators=$((server_indicators + 1)) ;;
        esac
    fi
    
    # Check for desktop environment
    if [ -n "${XDG_CURRENT_DESKTOP:-}" ]; then
        workstation_indicators=$((workstation_indicators + 1))
    else
        server_indicators=$((server_indicators + 1))
    fi
    
    # Check session type
    if [ -n "${XDG_SESSION_TYPE:-}" ] && [ "${XDG_SESSION_TYPE}" != "tty" ]; then
        workstation_indicators=$((workstation_indicators + 1))
    else
        server_indicators=$((server_indicators + 1))
    fi
    
    # Check for display manager service
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active display-manager >/dev/null 2>&1 || \
           systemctl is-active gdm >/dev/null 2>&1 || \
           systemctl is-active lightdm >/dev/null 2>&1 || \
           systemctl is-active sddm >/dev/null 2>&1; then
            workstation_indicators=$((workstation_indicators + 1))
        else
            server_indicators=$((server_indicators + 1))
        fi
    fi
    
    # Check for DISPLAY variable (but not if we're in SSH with X forwarding)
    if [ -n "${DISPLAY:-}" ] && [ -z "${SSH_CONNECTION:-}" ]; then
        workstation_indicators=$((workstation_indicators + 1))
    fi
    
    # Check for common desktop packages
    if command -v gnome-shell >/dev/null 2>&1 || \
       command -v plasmashell >/dev/null 2>&1 || \
       command -v xfce4-session >/dev/null 2>&1; then
        workstation_indicators=$((workstation_indicators + 1))
    fi
    
    # Determine system type
    if [ $workstation_indicators -gt $server_indicators ]; then
        echo "WORKSTATION"
    else
        echo "SERVER"
    fi
}

# Install GPU drivers (NVIDIA/AMD/Intel)
install_gpu_drivers() {
    echo "Detecting GPU..."
    
    local gpu_vendor
    gpu_vendor=$(detect_gpu_vendor)
    
    echo "GPU Vendor detected: $gpu_vendor"
    
    case "$gpu_vendor" in
        NVIDIA)
            install_nvidia_drivers
            ;;
        AMD)
            install_amd_drivers
            ;;
        Intel)
            install_intel_drivers
            ;;
        Unknown)
            echo "No supported GPU detected or unable to detect GPU vendor."
            ;;
    esac
}

# Install NVIDIA drivers
install_nvidia_drivers() {
    echo "Installing NVIDIA drivers..."
    
    local distro
    distro=$(detect_distribution)
    
    case "$distro" in
        ubuntu|debian)
            # Add graphics drivers PPA
            if command -v add-apt-repository >/dev/null 2>&1; then
                add-apt-repository -y ppa:graphics-drivers/ppa
                apt-get update
            fi
            
            # Install drivers
            if command -v ubuntu-drivers >/dev/null 2>&1; then
                ubuntu-drivers install
            else
                install_package nvidia-driver-535 nvidia-utils-535
            fi
            ;;
            
        rhel|rocky|centos)
            # Enable EPEL
            install_package epel-release
            
            # Add NVIDIA repo
            local rhel_version
            rhel_version=$(rpm -E %rhel)
            local cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/rhel${rhel_version}/x86_64/cuda-rhel${rhel_version}.repo"
            
            if command -v dnf >/dev/null 2>&1; then
                dnf config-manager --add-repo="$cuda_repo"
            else
                yum-config-manager --add-repo="$cuda_repo"
            fi
            
            # Install dependencies
            install_package kernel-devel-$(uname -r) kernel-headers-$(uname -r)
            install_package dkms gcc make
            
            # Install NVIDIA driver
            install_package nvidia-driver nvidia-settings
            
            # Blacklist nouveau
            echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf
            echo 'omit_drivers+=" nouveau "' > /etc/dracut.conf.d/blacklist-nouveau.conf
            
            # Rebuild initramfs
            dracut --regenerate-all --force
            ;;
            
        nixos)
            echo "NVIDIA configuration for NixOS requires manual configuration."
            cat >> "$NIXOS_CONFIG" << 'EOF'

# NVIDIA GPU configuration (added by vts-bootstrap)
hardware.nvidia = {
  modesetting.enable = true;
  package = config.boot.kernelPackages.nvidiaPackages.stable;
};
services.xserver.videoDrivers = ["nvidia"];
EOF
            echo "Configuration added to $NIXOS_CONFIG. Run: nixos-rebuild switch"
            ;;
    esac
    
    echo "NVIDIA driver installation completed."
}

# Install AMD drivers
install_amd_drivers() {
    echo "Installing AMD drivers..."
    
    local distro
    distro=$(detect_distribution)
    
    case "$distro" in
        ubuntu|debian)
            # For Ubuntu, use open-source drivers (AMDGPU) as AMDGPU-PRO has compatibility issues
            echo "Installing open-source AMD drivers..."
            
            # Install Mesa drivers
            install_package mesa-vulkan-drivers mesa-va-drivers mesa-vdpau-drivers
            install_package libdrm-amdgpu1 xserver-xorg-video-amdgpu
            
            # Optional: Add oibaf PPA for newer Mesa
            if command -v add-apt-repository >/dev/null 2>&1; then
                echo "Adding graphics drivers PPA for newer Mesa..."
                add-apt-repository -y ppa:oibaf/graphics-drivers
                apt-get update
                apt-get upgrade -y
            fi
            
            echo "Note: AMDGPU-PRO has compatibility issues with Ubuntu 22.04+."
            echo "Using open-source drivers which provide excellent performance."
            ;;
            
        rhel|rocky|centos)
            # Enable required repos
            install_package epel-release
            
            if command -v dnf >/dev/null 2>&1; then
                dnf config-manager --set-enabled crb || dnf config-manager --set-enabled powertools
            fi
            
            # Install AMDGPU
            echo "Installing AMDGPU drivers..."
            local amdgpu_repo="https://repo.radeon.com/amdgpu-install/6.0/rhel/$(rpm -E %rhel)/amdgpu-install.repo"
            
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "$amdgpu_repo"
                dnf install -y amdgpu-install
            else
                yum install -y "$amdgpu_repo"
                yum install -y amdgpu-install
            fi
            
            # Install with graphics and compute support
            amdgpu-install -y --usecase=graphics,rocm --vulkan=amdvlk,radv
            
            # Add user to video and render groups
            usermod -a -G video,render rootasp 2>/dev/null || true
            ;;
            
        nixos)
            echo "AMD configuration for NixOS requires manual configuration."
            cat >> "$NIXOS_CONFIG" << 'EOF'

# AMD GPU configuration (added by vts-bootstrap)
hardware.graphics = {
  enable = true;
  enable32Bit = true;
};
boot.initrd.kernelModules = [ "amdgpu" ];
services.xserver.videoDrivers = [ "amdgpu" ];
hardware.graphics.extraPackages = with pkgs; [
  amdvlk
];
EOF
            echo "Configuration added to $NIXOS_CONFIG. Run: nixos-rebuild switch"
            ;;
    esac
    
    echo "AMD driver installation completed."
}

# Install Intel drivers
install_intel_drivers() {
    echo "Installing Intel drivers..."
    
    local distro
    distro=$(detect_distribution)
    
    case "$distro" in
        ubuntu|debian)
            # Install Mesa and Intel-specific packages
            install_package mesa-vulkan-drivers mesa-va-drivers mesa-vdpau-drivers
            install_package intel-media-va-driver i965-va-driver
            install_package libva-intel-driver intel-gpu-tools
            
            # For newer Intel GPUs (Arc series)
            if lspci | grep -i "Intel.*Arc" >/dev/null 2>&1; then
                echo "Intel Arc GPU detected. Installing additional drivers..."
                
                # Add Intel GPU repository
                wget -qO - https://repositories.intel.com/graphics/intel-graphics.key | \
                    gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg
                
                echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/graphics/ubuntu $(lsb_release -cs) main" | \
                    tee /etc/apt/sources.list.d/intel-gpu-$(lsb_release -cs).list
                
                apt-get update
                install_package intel-opencl-icd intel-level-zero-gpu level-zero
                install_package intel-media-va-driver-non-free
            fi
            ;;
            
        rhel|rocky|centos)
            # Install Mesa packages
            install_package mesa-dri-drivers mesa-vulkan-drivers mesa-va-drivers
            install_package intel-media-driver libva-intel-driver
            
            # Intel official repository for newer features
            rpm --import https://repositories.intel.com/graphics/intel-graphics.key
            
            if command -v dnf >/dev/null 2>&1; then
                dnf config-manager --add-repo \
                    https://repositories.intel.com/graphics/rhel/$(rpm -E %rhel)/intel-graphics.repo
                dnf install -y intel-opencl intel-media libmfxgen1 libvpl2
            else
                yum-config-manager --add-repo \
                    https://repositories.intel.com/graphics/rhel/$(rpm -E %rhel)/intel-graphics.repo
                yum install -y intel-opencl intel-media libmfxgen1 libvpl2
            fi
            ;;
            
        nixos)
            echo "Intel configuration for NixOS requires manual configuration."
            cat >> "$NIXOS_CONFIG" << 'EOF'

# Intel GPU configuration (added by vts-bootstrap)
hardware.graphics = {
  enable = true;
  enable32Bit = true;
  extraPackages = with pkgs; [
    intel-media-driver
    intel-compute-runtime
    vpl-gpu-rt
  ];
};
boot.initrd.kernelModules = [ "i915" ];
EOF
            echo "Configuration added to $NIXOS_CONFIG. Run: nixos-rebuild switch"
            ;;
    esac
    
    echo "Intel driver installation completed."
}

# Install Devolutions Remote Desktop Manager
install_rdm() {
    echo "Installing Devolutions Remote Desktop Manager..."
    
    local distro
    distro=$(detect_distribution)
    
    case "$distro" in
        ubuntu|debian)
            # Add Devolutions repository
            echo "Adding Devolutions repository..."
            curl -1sLf 'https://dl.cloudsmith.io/public/devolutions/rdm/setup.deb.sh' | bash
            
            # Update package list
            apt-get update
            
            # Install RDM Free edition
            install_package remotedesktopmanager-free
            
            # Install dependencies if needed
            install_package ca-certificates-mozilla libsecret-1-0 libwebkit2gtk-4.0-37
            ;;
            
        rhel|rocky|centos)
            # Import GPG key
            rpm --import 'https://dl.cloudsmith.io/public/devolutions/rdm/gpg.FE7407ECB26FD2FE.key'
            
            # Add repository
            local rdm_repo_url="https://dl.cloudsmith.io/public/devolutions/rdm/config.rpm.txt?distro=el&codename=$(rpm -E %rhel)"
            curl -1sLf "$rdm_repo_url" > /tmp/devolutions-rdm.repo
            
            if command -v dnf >/dev/null 2>&1; then
                dnf config-manager --add-repo '/tmp/devolutions-rdm.repo'
                dnf install -y remotedesktopmanager-free
            else
                yum-config-manager --add-repo '/tmp/devolutions-rdm.repo'
                yum install -y remotedesktopmanager-free
            fi
            
            rm -f /tmp/devolutions-rdm.repo
            ;;
            
        nixos)
            echo "Devolutions RDM is not in nixpkgs. Installing via Flatpak..."
            
            # Check if Flatpak is enabled
            if ! command -v flatpak >/dev/null 2>&1; then
                echo "Flatpak is not available. Add to configuration.nix:"
                echo "services.flatpak.enable = true;"
                echo ""
                echo "After enabling Flatpak, run:"
                echo "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
                echo "flatpak install flathub net.devolutions.RDM"
            else
                # Install via Flatpak
                flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
                flatpak install -y flathub net.devolutions.RDM
            fi
            ;;
            
        *)
            echo "Unsupported distribution for RDM installation: $distro"
            return 1
            ;;
    esac
    
    echo "Devolutions Remote Desktop Manager installation completed."
    echo "Note: Free edition requires registration after 30-day trial."
    echo "Launch with: remotedesktopmanager (or from application menu)"
}

# Wrapper for nvidia() to maintain backward compatibility
# This allows users who were using "-m nvidia" to continue working
nvidia() {
    install_gpu_drivers
}

# Install packages
install_packages() {
    echo "Installing required packages..."
    
    local distro
    distro=$(detect_distribution)
    
    # Common packages with name mapping
    local packages=""
    for pkg in vim wget curl tmux unzip git htop pciutils; do
        mapped=$(map_package_names "$pkg")
        packages="$packages $mapped"
    done
    
    # Distribution specific packages
    case "$distro" in
        ubuntu|debian)
            packages="$packages linux-headers-$(uname -r) dkms"
            packages="$packages clevis clevis-luks clevis-tpm2"
            packages="$packages ansible whois cifs-utils usbutils"
            packages="$packages net-tools iputils-ping lshw"
            # Basic Mesa packages for GPU support
            packages="$packages mesa-utils mesa-vulkan-drivers"
            ;;
        rhel|rocky|centos)
            packages="$packages kernel-devel-$(uname -r) dkms"
            packages="$packages clevis clevis-luks clevis-systemd"
            packages="$packages ansible whois cifs-utils usbutils"
            packages="$packages net-tools iputils lshw"
            # Basic Mesa packages for GPU support
            packages="$packages mesa-dri-drivers mesa-vulkan-drivers"
            ;;
        nixos)
            # NixOS packages are handled differently
            nix-env -iA nixpkgs.vim nixpkgs.wget nixpkgs.curl nixpkgs.tmux
            nix-env -iA nixpkgs.unzip nixpkgs.git nixpkgs.htop nixpkgs.pciutils
            nix-env -iA nixpkgs.clevis nixpkgs.ansible
            nix-env -iA nixpkgs.whois nixpkgs.cifs-utils
            nix-env -iA nixpkgs.usbutils nixpkgs.lshw
            nix-env -iA nixpkgs.nettools nixpkgs.iputils
            nix-env -iA nixpkgs.mesa nixpkgs.mesa-demos
            return 0
            ;;
    esac
    
    # Update system first
    update_system
    
    # Install packages
    for pkg in $packages; do
        if [ -n "$pkg" ]; then
            install_package "$pkg" || echo "Warning: Failed to install $pkg"
        fi
    done
    
    echo "Package installation completed."
}

# Install RMM agent
rmm() {
    echo "Installing RMM agent..."
    
    local distro
    distro=$(detect_distribution)
    
    # RMM configuration
    local agentDL='https://agents.tacticalrmm.com/api/v2/agents/?version=2.5.0&arch=amd64&token=c3c119ef-cc60-4aab-9638-ca05cf5ec020&plat=linux&api=api.vtstools.com'
    local meshDL='https://mesh.vtstools.com/meshagents?id=g02QAv0FP3rG8LSnKG7VPjsiTfNxbWw8J@@BTKbK0Pc0Zex9eWiznqv4aC92z41T&installflags=2&meshinstall=6'
    local apiURL='https://api.vtstools.com'
    local token='04fe17b8e8033b848fa6cad8c530b1b07dc65628e1f52ec55579bded75735e54'
    local clientID='1'
    local siteID='1'
    local agentType='server'
    local agentBinPath='/usr/local/bin'
    local binName='tacticalagent'
    local agentBin="${agentBinPath}/${binName}"
    local agentConf='/etc/tacticalagent'
    local agentSvcName='tacticalagent.service'
    local agentSysD="/etc/systemd/system/${agentSvcName}"
    local meshDir='/opt/tacticalmesh'
    local meshSystemBin="${meshDir}/meshagent"
    local meshSvcName='meshagent.service'
    
    # Check if systemd is available (skip for NixOS)
    if [ "$distro" = "nixos" ]; then
        echo "RMM agent installation on NixOS requires special handling."
        echo "Please configure the agent as a NixOS service."
        return 0
    fi
    
    # Remove old agent if exists
    if [ -f "${agentSysD}" ]; then
        systemctl stop ${agentSvcName} 2>/dev/null || true
        systemctl disable ${agentSvcName} 2>/dev/null || true
        rm -f ${agentSysD}
        systemctl daemon-reload
    fi
    
    [ -f "${agentConf}" ] && rm -f ${agentConf}
    [ -f "${agentBin}" ] && rm -f ${agentBin}
    
    # Download agent
    echo "Downloading tactical agent..."
    if command -v wget >/dev/null 2>&1; then
        wget -q -O ${agentBin} "${agentDL}"
    elif command -v curl >/dev/null 2>&1; then
        curl -sL -o ${agentBin} "${agentDL}"
    else
        echo "ERROR: Neither wget nor curl found"
        return 1
    fi
    
    chmod +x ${agentBin}
    
    # Install mesh agent
    echo "Installing mesh agent..."
    local meshTmpDir='/tmp/meshtemp'
    mkdir -p $meshTmpDir
    local meshTmpBin="${meshTmpDir}/meshagent"
    
    if command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -q -O ${meshTmpBin} ${meshDL}
    else
        curl -skL -o ${meshTmpBin} ${meshDL}
    fi
    
    chmod +x ${meshTmpBin}
    mkdir -p ${meshDir}
    
    # Install mesh with proper environment
    env LC_ALL=C.UTF-8 LANGUAGE=en_US XAUTHORITY=foo DISPLAY=bar ${meshTmpBin} -install --installPath=${meshDir}
    
    sleep 2
    rm -rf ${meshTmpDir}
    
    # Get mesh node ID
    local MESH_NODE_ID=""
    if [ -f "${meshSystemBin}" ]; then
        MESH_NODE_ID=$(env XAUTHORITY=foo DISPLAY=bar ${agentBin} -m nixmeshnodeid 2>/dev/null || echo "")
    fi
    
    # Install agent
    local INSTALL_CMD="${agentBin} -m install -api ${apiURL} -client-id ${clientID} -site-id ${siteID} -agent-type ${agentType} -auth ${token}"
    
    if [ -n "${MESH_NODE_ID}" ]; then
        INSTALL_CMD="${INSTALL_CMD} --meshnodeid ${MESH_NODE_ID}"
    fi
    
    eval ${INSTALL_CMD}
    
    # Create systemd service
    cat > ${agentSysD} << EOF
[Unit]
Description=Tactical RMM Linux Agent
After=network-online.target
Wants=network-online.target

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
    
    # Enable and start service
    systemctl daemon-reload
    systemctl enable ${agentSvcName}
    systemctl start ${agentSvcName}
    
    echo "RMM agent installation completed."
}

# Set timezone
settime() {
    echo "Setting timezone to Europe/London..."
    
    local distro
    distro=$(detect_distribution)
    
    case "$distro" in
        nixos)
            echo "For NixOS, add to configuration.nix:"
            echo "time.timeZone = \"Europe/London\";"
            ;;
        *)
            if command -v timedatectl >/dev/null 2>&1; then
                timedatectl set-timezone Europe/London
            else
                ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
                echo "Europe/London" > /etc/timezone
            fi
            ;;
    esac
    
    echo "Timezone configuration completed."
}

# Install Docker
docker() {
    echo "Installing Docker..."
    
    local distro
    distro=$(detect_distribution)
    
    case "$distro" in
        ubuntu|debian)
            # Remove old versions
            apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            
            # Install prerequisites
            install_package ca-certificates curl gnupg lsb-release
            
            # Add Docker's GPG key
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
            
            # Add repository
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID \
              $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Install Docker
            apt-get update
            install_package docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
            
        rhel|rocky|centos)
            # Remove podman if present
            if rpm -q podman >/dev/null 2>&1; then
                echo "Removing podman..."
                if command -v dnf >/dev/null 2>&1; then
                    dnf remove -y podman buildah
                else
                    yum remove -y podman buildah
                fi
            fi
            
            # Install prerequisites
            install_package yum-utils
            
            # Add Docker repository
            if command -v dnf >/dev/null 2>&1; then
                dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            else
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            fi
            
            # Install Docker
            install_package docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
            
        nixos)
            echo "For NixOS, add to configuration.nix:"
            echo ""
            echo "virtualisation.docker = {"
            echo "  enable = true;"
            echo "  enableOnBoot = true;"
            echo "};"
            echo ""
            echo "# Add your user to docker group:"
            echo "users.users.rootasp.extraGroups = [ \"docker\" ];"
            echo ""
            echo "Then run: nixos-rebuild switch"
            return 0
            ;;
    esac
    
    # Start and enable Docker
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start docker
        systemctl enable docker
    fi
    
    # Add rootasp user to docker group if user exists
    if id rootasp >/dev/null 2>&1 && command -v usermod >/dev/null 2>&1; then
        usermod -aG docker rootasp
    fi
    
    # Install docker-compose standalone if not available
    if ! command -v docker-compose >/dev/null 2>&1; then
        echo "Installing docker-compose..."
        local compose_version="v2.23.0"
        local compose_url="https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)"
        
        if command -v curl >/dev/null 2>&1; then
            curl -L "$compose_url" -o /usr/local/bin/docker-compose
        else
            wget -O /usr/local/bin/docker-compose "$compose_url"
        fi
        
        chmod +x /usr/local/bin/docker-compose
    fi
    
    # Test Docker installation
    if command -v docker >/dev/null 2>&1; then
        docker --version
        echo "Docker installation completed successfully."
    else
        echo "Warning: Docker installation may have failed."
    fi
}

# Post-run cleanup
postrun() {
    echo "Performing post-run cleanup..."
    
    # Clean package caches
    local pkg_manager
    pkg_manager=$(get_package_manager)
    
    case "$pkg_manager" in
        apt)
            apt-get clean
            apt-get autoclean
            apt-get autoremove -y
            ;;
        dnf)
            dnf clean all
            ;;
        yum)
            yum clean all
            rm -rf /var/cache/yum
            ;;
        nix)
            nix-collect-garbage -d
            ;;
    esac
    
    # Clear temp files
    rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
    
    echo "Post-run cleanup completed."
}

# Mark completion and send notification
markdone() {
    echo "Bootstrap process completed. Sending notification..."
    
    local distro
    distro=$(detect_distribution)
    
    local pkg_manager
    pkg_manager=$(get_package_manager)
    
    local system_type
    system_type=$(detect_system_type)
    
    local gpu_vendor
    gpu_vendor=$(detect_gpu_vendor)
    
    local subject="Bootstrap Complete: $HOSTNAME"
    local body="Bootstrap script completed successfully.

Host: $HOSTNAME
IP: $IP
Date: $(date)
Distribution: $distro
Package Manager: $pkg_manager
OS Version: $OS_VERSION
System Type: $system_type
GPU Vendor: $gpu_vendor

Installed Components:
- User: rootasp (with sudo access)
- Packages: System utilities and dependencies
- GPU Drivers: $gpu_vendor drivers installed/configured
- RMM Agent: Tactical RMM agent installed
- Docker: Container runtime installed"
    
    if [ "$system_type" = "WORKSTATION" ]; then
        body="$body
- Remote Desktop Manager: Devolutions RDM installed"
    fi
    
    body="$body

The system will reboot in 30 seconds.
"
    
    send_email "$subject" "$body"
    
    # Schedule reboot
    echo "System will reboot in 30 seconds..."
    
    if [ "$distro" = "nixos" ]; then
        echo "Please reboot manually after running: nixos-rebuild switch"
    else
        if command -v shutdown >/dev/null 2>&1; then
            shutdown -r +1 "Bootstrap completed. System rebooting..."
        else
            sleep 30
            reboot
        fi
    fi
}

# Main execution function
do_all() {
    echo "Starting full bootstrap process..."
    
    local modules="setupusers install_packages nvidia rmm settime docker postrun"
    
    for module in $modules; do
        echo ""
        echo "=== Running module: $module ==="
        if type "$module" >/dev/null 2>&1; then
            if ! $module; then
                echo "ERROR: Module $module failed"
                return 1
            fi
        else
            echo "Warning: Module $module not found"
        fi
    done
    
    echo ""
    echo "All modules completed successfully."
    return 0
}

# Initialize
init_logging
setup_system_info

# Check prerequisites
if ! check_systemd; then
    echo "ERROR: System requirements not met"
    exit 1
fi

# Display system information
echo "System Information:"
echo "  Hostname: $HOSTNAME"
echo "  IP: $IP"
echo "  Distribution: $(detect_distribution)"
echo "  Package Manager: $(get_package_manager)"
echo "  OS Version: $OS_VERSION"
echo ""

# Execute requested module(s)
case "$MODULE" in
    all)
        if do_all; then
            markdone
        else
            echo "Bootstrap failed!"
            exit 1
        fi
        ;;
    setupusers|nvidia|packages|rmm|postrun|settime|docker|markdone)
        if [ "$MODULE" = "packages" ]; then
            install_packages
        else
            $MODULE
        fi
        ;;
    *)
        echo "ERROR: Unknown module: $MODULE"
        usage
        ;;
esac

echo "=== Bootstrap completed at $(date) ==="
