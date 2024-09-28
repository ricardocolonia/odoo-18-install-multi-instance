#!/bin/bash
################################################################################
# Script to remove an Odoo instance from the server
#-------------------------------------------------------------------------------
# This script lists the installed Odoo instances, allows you to select one to
# remove, and then removes it without affecting other instances.
#-------------------------------------------------------------------------------
# Usage:
# 1. Save it as remove-odoo-instance.sh
#    sudo nano remove-odoo-instance.sh
# 2. Make the script executable:
#    sudo chmod +x remove-odoo-instance.sh
# 3. Run the script:
#    sudo ./remove-odoo-instance.sh
################################################################################

# Variables
OE_USER="odoo"

# Function to list instances
list_instances() {
    echo "Installed Odoo Instances:"
    INSTANCE_CONFIG_FILES=(/etc/${OE_USER}-server-*.conf)
    INSTANCE_NAMES=()
    INDEX=1
    for CONFIG_FILE in "${INSTANCE_CONFIG_FILES[@]}"; do
        INSTANCE_NAME=$(basename "$CONFIG_FILE" | sed "s/${OE_USER}-server-//" | sed 's/\.conf//')
        echo "$INDEX) $INSTANCE_NAME"
        INSTANCE_NAMES[$INDEX]=$INSTANCE_NAME
        INDEX=$((INDEX + 1))
    done
}

# Check if there are any instances
if [ ! -f /etc/${OE_USER}-server-*.conf ]; then
    echo "No Odoo instances found."
    exit 1
fi

# List instances
list_instances

# Prompt user to select an instance to remove
read -p "Enter the number of the instance you want to remove: " INSTANCE_NUMBER

# Validate input
if ! [[ "$INSTANCE_NUMBER" =~ ^[0-9]+$ ]] || [ -z "${INSTANCE_NAMES[$INSTANCE_NUMBER]}" ]; then
    echo "Invalid selection."
    exit 1
fi

INSTANCE_NAME=${INSTANCE_NAMES[$INSTANCE_NUMBER]}
OE_CONFIG="${OE_USER}-server-${INSTANCE_NAME}"
SERVICE_FILE="/etc/systemd/system/${OE_CONFIG}.service"
CONFIG_FILE="/etc/${OE_CONFIG}.conf"
LOG_FILE="/var/log/${OE_USER}/${OE_CONFIG}.log"
INSTANCE_DIR="/${OE_USER}/${INSTANCE_NAME}"
NGINX_CONF_FILE="/etc/nginx/sites-available/${INSTANCE_NAME}"
NGINX_ENABLED_FILE="/etc/nginx/sites-enabled/${INSTANCE_NAME}"

echo "You have selected to remove instance: $INSTANCE_NAME"

# Confirm removal
read -p "Are you sure you want to remove this instance? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborting removal."
    exit 0
fi

# Stop the service
echo "Stopping Odoo service..."
sudo systemctl stop "${OE_CONFIG}.service"
sudo systemctl disable "${OE_CONFIG}.service"

# Remove systemd service file
echo "Removing systemd service file..."
sudo rm -f "$SERVICE_FILE"

# Remove Odoo configuration file
echo "Removing Odoo configuration file..."
sudo rm -f "$CONFIG_FILE"

# Remove log file
echo "Removing log file..."
sudo rm -f "$LOG_FILE"

# Remove custom addons directory
echo "Removing custom addons directory..."
sudo rm -rf "$INSTANCE_DIR"

# Remove Nginx configuration if exists
if [ -f "$NGINX_CONF_FILE" ]; then
    echo "Removing Nginx configuration..."
    sudo rm -f "$NGINX_CONF_FILE"
    sudo rm -f "$NGINX_ENABLED_FILE"
    # Reload Nginx
    sudo nginx -t && sudo systemctl reload nginx
fi

# Remove instance from port tracking (if any)
echo "Instance $INSTANCE_NAME has been removed."

# Reload systemd daemon
sudo systemctl daemon-reload

echo "Odoo instance $INSTANCE_NAME successfully removed."
