#!/bin/bash

# Script to set up LXD, launch a container, and install CloudPanel.
# This script automates the initial infrastructure setup.
# Further configuration of CloudPanel and GitHub integration is manual.

# --- Configuration Variables ---
# You can modify these if needed, or adapt the script to take them as arguments.
CONTAINER_NAME="webhost-lxc"
CONTAINER_OS_IMAGE="ubuntu:22.04" # CloudPanel supports Ubuntu 22.04 [1, 2, 3]
LXD_STORAGE_BACKEND="dir"         # Using 'dir' for simplicity and wider compatibility.
                                  # ZFS is an option but requires ZFS tools and kernel support.
LXD_STORAGE_POOL_NAME="default"

# --- Helper Functions ---
print_info() {
    echo -e "\033[1;34m[INFO]\033\033\033[0m $1"
}

check_command_success() {
    if [ $? -ne 0 ]; then
        print_error "\"$1\" failed. Exiting."
        exit 1
    fi
    print_info "\"$1\" completed successfully."
}

# --- Main Script ---

# 1. Check for root/sudo privileges
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run with sudo or as root. Example: sudo./setup_lxc_cloudpanel.sh"
    exit 1
fi

print_info "Starting LXC Host, Container, and CloudPanel Installation Script..."
echo "---------------------------------------------------------------------"

# 2. Host System Preparation
print_info "Updating host system packages (apt update && apt upgrade -y)..."
apt update > /dev/null 2>&1 && apt upgrade -y > /dev/null 2>&1
check_command_success "Host system package update"

print_info "Ensuring LXD (snap package) is installed..."
if! command -v snap &> /dev/null; then
    print_info "snapd not found. Installing snapd..."
    apt install snapd -y > /dev/null 2>&1
    check_command_success "snapd installation"
fi

if! snap list lxd &> /dev/null; then
    snap install lxd
    check_command_success "LXD snap installation"
else
    print_info "LXD snap is already installed."
fi

# Add current sudo user to lxd group
SUDO_USER_TO_ADD=${SUDO_USER:-$(logname 2>/dev/null |
| echo "")} # Get user who invoked sudo

if &&; then
    if! groups "$SUDO_USER_TO_ADD" | grep -q '\blxd\b'; then
        print_info "Adding user '$SUDO_USER_TO_ADD' to the 'lxd' group..."
        usermod -a -G lxd "$SUDO_USER_TO_ADD"
        check_command_success "Adding $SUDO_USER_TO_ADD to lxd group"
        print_warning "User '$SUDO_USER_TO_ADD' has been added to the 'lxd' group. A new login session (or 'newgrp lxd') is required for this change to take effect for that user to run lxc commands without sudo."
    else
        print_info "User '$SUDO_USER_TO_ADD' is already in the 'lxd' group."
    fi
else
    print_warning "Running as root or could not determine sudo user. 'lxc' commands will be run as root by this script. If you intend to manage LXD as a non-root user, ensure they are in the 'lxd' group."
fi


print_info "Initializing LXD if not already initialized (lxd init --auto)..."
# Check if LXD is already initialized by looking for the default storage pool or network
if! lxc storage show "$LXD_STORAGE_POOL_NAME" &> /dev/null ||! lxc network show lxdbr0 &> /dev/null; then
    lxd init --auto --storage-backend "$LXD_STORAGE_BACKEND" --storage-create-device "$LXD_STORAGE_POOL_NAME"
    check_command_success "LXD initialization (lxd init)"
else
    print_info "LXD appears to be already initialized. Skipping 'lxd init'."
fi


# 3. Launch and Configure LXC Container
print_info "Launching LXC container '$CONTAINER_NAME' with image '$CONTAINER_OS_IMAGE'..."
if lxc info "$CONTAINER_NAME" &> /dev/null; then
    print_warning "Container '$CONTAINER_NAME' already exists. Ensuring it is started."
    if! lxc info "$CONTAINER_NAME" | grep -q "Status: RUNNING"; then
        lxc start "$CONTAINER_NAME"
        check_command_success "Starting existing container '$CONTAINER_NAME'"
        sleep 10 # Give some time for network to come up
    fi
else
    lxc launch "$CONTAINER_OS_IMAGE" "$CONTAINER_NAME"
    check_command_success "LXC container launch"
    print_info "Waiting for container to get an IP address (approx. 15-30 seconds)..."
    sleep 20 # Give some time for the container to boot and get network
fi

# Get container IP
CONTAINER_IP=""
RETRY_COUNT=0
MAX_RETRIES=5
while &&; do
    CONTAINER_IP=$(lxc list "$CONTAINER_NAME" --format csv -c 4 | grep -vE '(^$|NAME|IPV4)' | head -n 1)
    if; then
        # Fallback method
        CONTAINER_IP=$(lxc info "$CONTAINER_NAME" | grep -E 'eth0:.*inet\s' | awk '{print $3}' | cut -d'/' -f1 | head -n 1)
    fi
    if; then
        sleep 5
        RETRY_COUNT=$((RETRY_COUNT + 1))
    fi
done

if; then
    print_warning "Could not automatically determine container IP after $MAX_RETRIES retries. Manual check might be needed using 'lxc list $CONTAINER_NAME'."
else
    print_info "Container '$CONTAINER_NAME' IP Address: $CONTAINER_IP"
fi


print_info "Updating packages within the container '$CONTAINER_NAME'..."
lxc exec "$CONTAINER_NAME" -- apt-get update # apt-get for non-interactive
check_command_success "Container package list update (apt-get update)"
lxc exec "$CONTAINER_NAME" -- apt-get upgrade -y
check_command_success "Container package upgrade (apt-get upgrade -y)"

print_info "Installing dependencies (curl, wget, sudo) in container '$CONTAINER_NAME'..."
lxc exec "$CONTAINER_NAME" -- apt-get install curl wget sudo -y
check_command_success "Container dependency installation"

# 4. Install CloudPanel in the Container
print_info "Starting CloudPanel installation in container '$CONTAINER_NAME'..."
print_warning "The CloudPanel installation script will run now. This may take 5-15 minutes."
print_warning "You WILL BE PROMPTED by the CloudPanel script to choose a database engine (e.g., MariaDB or MySQL). Please monitor the terminal for this prompt."

CLOUDPANEL_INSTALL_COMMAND="curl -sS https://installer.cloudpanel.io/ce/v2/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh"
# Execute the command. Success/failure is determined by the CloudPanel script itself.
lxc exec "$CONTAINER_NAME" -- bash -c "$CLOUDPANEL_INSTALL_COMMAND"

# A basic check: see if CloudPanel port 8443 is listening inside the container after some time
sleep 60 # Give CloudPanel some time to potentially finish and start services
if lxc exec "$CONTAINER_NAME" -- ss -tulnp | grep -q ':8443'; then
    print_info "CloudPanel installation script seems to have run. Port 8443 is listening in the container."
else
    print_warning "CloudPanel installation script finished, but port 8443 was not detected as listening in the container after 1 minute. Please check the output above for errors from the CloudPanel installer. You may need to access the container ('lxc exec $CONTAINER_NAME -- bash') to troubleshoot."
fi

# 5. Expose Web Server Ports (HTTP/HTTPS) and CloudPanel Admin Port from container to host
print_info "Setting up LXD proxy devices for HTTP (80), HTTPS (443), and CloudPanel Admin (8443) for container '$CONTAINER_NAME'..."

# Port 80
if! lxc config device get "$CONTAINER_NAME" myport80 proxy &> /dev/null; then
    lxc config device add "$CONTAINER_NAME" myport80 proxy listen=tcp:0.0.0.0:80 connect=tcp:127.0.0.1:80
    check_command_success "Adding proxy for port 80"
else
    print_info "Proxy device myport80 already exists for '$CONTAINER_NAME'."
fi

# Port 443
if! lxc config device get "$CONTAINER_NAME" myport443 proxy &> /dev/null; then
    lxc config device add "$CONTAINER_NAME" myport443 proxy listen=tcp:0.0.0.0:443 connect=tcp:127.0.0.1:443
    check_command_success "Adding proxy for port 443"
else
    print_info "Proxy device myport443 already exists for '$CONTAINER_NAME'."
fi

# CloudPanel Admin Port 8443
if! lxc config device get "$CONTAINER_NAME" clpadminport proxy &> /dev/null; then
    lxc config device add "$CONTAINER_NAME" clpadminport proxy listen=tcp:0.0.0.0:8443 connect=tcp:127.0.0.1:8443
    check_command_success "Adding proxy for CloudPanel admin port 8443"
else
    print_info "Proxy device clpadminport already exists for '$CONTAINER_NAME'."
fi

echo ""
print_info "---------------------------------------------------------------------"
print_info "LXC Host, Container, and Initial CloudPanel Setup Script Finished."
print_info "---------------------------------------------------------------------"
echo ""
print_warning "IMPORTANT NEXT STEPS (Manual):"
print_info "1. Access CloudPanel Admin UI:"
print_info "   - If your host has a public IP: https://<HOST_PUBLIC_IP>:8443"
if; then
    print_info "   - If accessing from host or local network: https://$CONTAINER_IP:8443 (Container IP)"
else
    print_warning "   - Container IP could not be determined. Use 'lxc list $CONTAINER_NAME' on the host to find it."
fi
print_info "   You will likely see a browser warning for a self-signed certificate. Proceed to access."
print_info "2. Create your CloudPanel administrator account when prompted on the first visit."
print_info "3. Inside CloudPanel: Configure your domain(s), SSL certificates (Let's Encrypt is supported), and databases as needed."
print_info "4. For GitHub Integration (Automated Deployments):"
print_info "   a. Access your container: lxc exec $CONTAINER_NAME -- bash"
print_info "   b. Install 'dploy': curl -sS https://dploy.cloudpanel.io/dploy -o /usr/local/bin/dploy && sudo chmod +x /usr/local/bin/dploy [2]"
print_info "   c. As the specific site user (created by CloudPanel when you add a site):"
print_info "      - Run 'dploy init' in the site's intended deployment root."
print_info "      - Generate an SSH key pair for GitHub deployment (ssh-keygen)."
print_info "      - Add the public key as a Deploy Key to your GitHub repository."
print_info "      - Configure '~/.ssh/config' for the site user to use this key for github.com."
print_info "      - Edit '~/.dploy/config.yml' with your repository URL, target path, shared directories/files, and necessary hooks (e.g., PHP-FPM reload for PHP sites).[2, 4]"
print_info "      - Ensure the site user has sudo permission for PHP-FPM reload if needed (via /etc/sudoers.d/)."
print_info "   d. Update the site's document root in CloudPanel to point to the 'current/public_html' (or similar) symlink managed by dploy."
print_info "   e. Consider setting up GitHub Actions for fully automated CI/CD as detailed in the research report (Section VI-B-4)."
print_info "5. Review and implement security best practices for the host, LXD, the container, CloudPanel, and your web applications (Section VII of the research report)."

if &&; then
    if! groups "$SUDO_USER_TO_ADD" | grep -q '\blxd\b'; then # Re-check in case script was run by root directly
         print_warning "Remember: User '$SUDO_USER_TO_ADD' was added to the 'lxd' group. A new login session is required for this to take full effect for that user to run lxc commands without sudo."
    fi
fi
echo ""
print_info "Script execution complete."
exit 0