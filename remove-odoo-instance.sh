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
OE_HOME="/odoo"  # Changed to match your previous request
OE_HOME_EXT="/odoo/${OE_USER}-server"
INSTANCE_CONFIG_PATH="/etc"

# Arrays to store existing instances
declare -a EXISTING_INSTANCE_NAMES

# Function to terminate active connections to a PostgreSQL database
terminate_db_connections() {
    local DB_NAME=$1

    echo "* Terminating active connections to database \"$DB_NAME\""
    
    # Terminate connections using pg_terminate_backend
    sudo -u postgres psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();"
}

# Gather existing instances
INSTANCE_CONFIG_FILES=(${INSTANCE_CONFIG_PATH}/${OE_USER}-server-*.conf)
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

# Remove the PostgreSQL databases and user
echo "* Dropping all databases owned by the PostgreSQL user $DB_USER"

# Fetch all databases owned by the user
DBS=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = '$DB_USER');")

for DB in $DBS; do
    # Trim whitespace from the database name
    DB=$(echo $DB | xargs)
    
    if [[ "$DB" == "postgres" ]]; then
        echo "* Skipping the default 'postgres' database."
        continue
    fi

    # Terminate active connections to the database
    terminate_db_connections "$DB"

    echo "* Dropping database \"$DB\""
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$DB\";"
done

echo "* Dropping the PostgreSQL user"
sudo -u postgres psql -c "DROP USER IF EXISTS $DB_USER;"

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

echo "Instance '$INSTANCE_NAME' has been deleted successfully."
