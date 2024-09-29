#!/bin/bash
################################################################################
# Script to remove an Odoo instance from an existing server setup
#-------------------------------------------------------------------------------
# This script allows you to select an Odoo instance from the list of installed
# instances and deletes it, including its PostgreSQL user, service, and config.
#-------------------------------------------------------------------------------
# Usage:
# 1. Save it as remove-odoo-instance.sh
#    sudo nano remove-odoo-instance.sh
# 2. Make the script executable:
#    sudo chmod +x remove-odoo-instance.sh
# 3. Run the script:
#    sudo ./remove-odoo-instance.sh
################################################################################

OE_USER="odoo"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"
INSTANCE_CONFIG_PATH="/etc"

# Arrays to store existing instances
declare -a EXISTING_INSTANCE_NAMES

# Gather existing instances
INSTANCE_CONFIG_FILES=(/etc/${OE_USER}-server-*.conf)
if [ -f "${INSTANCE_CONFIG_FILES[0]}" ]; then
    for CONFIG_FILE in "${INSTANCE_CONFIG_FILES[@]}"; do
        INSTANCE_NAME=$(basename "$CONFIG_FILE" | sed "s/${OE_USER}-server-//" | sed 's/\.conf//')
        EXISTING_INSTANCE_NAMES+=("$INSTANCE_NAME")
    done
else
    echo "No existing Odoo instances found."
    exit 1
fi

# Display the list of instances to the user
echo "Available Odoo instances:"
for i in "${!EXISTING_INSTANCE_NAMES[@]}"; do
    echo "$i) ${EXISTING_INSTANCE_NAMES[$i]}"
done

# Prompt the user to select an instance to delete
read -p "Enter the number of the instance you want to delete: " INSTANCE_INDEX
INSTANCE_NAME="${EXISTING_INSTANCE_NAMES[$INSTANCE_INDEX]}"

if [[ -z "$INSTANCE_NAME" ]]; then
    echo "Invalid selection. Exiting."
    exit 1
fi

# Confirmation
read -p "Are you sure you want to delete the instance '$INSTANCE_NAME'? This action cannot be undone. (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Operation canceled."
    exit 1
fi

# Variables for the instance
OE_CONFIG="${OE_USER}-server-${INSTANCE_NAME}"
DB_USER=$INSTANCE_NAME
NGINX_CONF_FILE="/etc/nginx/sites-available/${INSTANCE_NAME}"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${OE_CONFIG}.service"
INSTANCE_DIR="$OE_HOME/$INSTANCE_NAME"

echo "Deleting Odoo instance '$INSTANCE_NAME'..."

# Stop the Odoo systemd service
echo "* Stopping the Odoo service for $INSTANCE_NAME"
sudo systemctl stop ${OE_CONFIG}.service
sudo systemctl disable ${OE_CONFIG}.service

# Remove the systemd service file
echo "* Removing the systemd service file"
sudo rm -f $SYSTEMD_SERVICE_FILE
sudo systemctl daemon-reload

# Remove the PostgreSQL database and user
echo "* Dropping the PostgreSQL database"
sudo -u postgres psql -c "DROP DATABASE IF EXISTS $INSTANCE_NAME;"

echo "* Dropping the PostgreSQL user"
sudo -u postgres psql -c "DROP USER IF EXISTS $INSTANCE_NAME;"

# Remove the Odoo configuration file
echo "* Removing the Odoo configuration file"
sudo rm -f /etc/${OE_CONFIG}.conf

# Remove the instance directory
echo "* Removing the instance directory"
sudo rm -rf $INSTANCE_DIR

# Remove the Nginx configuration if it exists
if [ -f "$NGINX_CONF_FILE" ]; then
    echo "* Removing Nginx configuration"
    sudo rm -f "$NGINX_CONF_FILE"
    sudo rm -f "/etc/nginx/sites-enabled/${INSTANCE_NAME}"
    sudo systemctl reload nginx
fi

echo "Instance $INSTANCE_NAME has been deleted successfully."

