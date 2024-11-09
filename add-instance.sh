#!/bin/bash
################################################################################
# Script to add an Odoo instance to an existing server setup
#-------------------------------------------------------------------------------
# This script checks which instances are already installed, identifies available
# ports, and adds a new Odoo instance with the chosen configuration.
#-------------------------------------------------------------------------------
# Usage:
# 1. Save it as add-odoo-instance.sh
#    sudo nano add-odoo-instance.sh
# 2. Make the script executable:
#    sudo chmod +x add-odoo-instance.sh
# 3. Run the script:
#    sudo ./add-odoo-instance.sh
################################################################################

# Exit immediately if a command exits with a non-zero status
set -e

# Function to generate a random password
generate_random_password() {
    openssl rand -base64 16
}

# Ensure required packages are installed
install_package() {
    local PACKAGE=$1
    if ! dpkg -s "$PACKAGE" &> /dev/null; then
        echo "$PACKAGE could not be found. Installing $PACKAGE..."
        sudo apt update
        sudo apt install "$PACKAGE" -y
    fi
}

# Ensure necessary packages are installed
install_package "lsof"
install_package "nginx"
install_package "snapd"

# Install Certbot if not installed
if ! command -v certbot &> /dev/null; then
    echo "Installing Certbot..."
    sudo snap install core
    sudo snap refresh core
    sudo snap install --classic certbot
    sudo ln -sf /snap/bin/certbot /usr/bin/certbot
fi

# Base variables
OE_USER="odoo"
INSTALL_WKHTMLTOPDF="True"
GENERATE_RANDOM_PASSWORD="True"
BASE_ODOO_PORT=8069
BASE_GEVENT_PORT=9069  # Updated base port for gevent

# Get server IP address
SERVER_IP=$(hostname -I | awk '{print $1}')

# Arrays to store existing instances and ports
declare -a EXISTING_INSTANCE_NAMES
declare -a EXISTING_OE_PORTS
declare -a EXISTING_GEVENT_PORTS

# Prompt for Odoo version
read -p "Enter the Odoo version for this instance (17 or 18): " OE_VERSION_INPUT
if [ "$OE_VERSION_INPUT" == "17" ]; then
    OE_VERSION="17.0"
    PYTHON_VERSION="3.10"
elif [ "$OE_VERSION_INPUT" == "18" ]; then
    OE_VERSION="18.0"
    PYTHON_VERSION="3.11"
else
    echo "Invalid Odoo version. Please enter 17 or 18."
    exit 1
fi

# Install the required Python version if not already installed
if ! command -v python${PYTHON_VERSION} &> /dev/null; then
    echo "Python ${PYTHON_VERSION} is not installed. Installing Python ${PYTHON_VERSION}..."
    sudo apt update
    sudo apt install software-properties-common -y
    sudo add-apt-repository ppa:deadsnakes/ppa -y
    sudo apt update
    sudo apt install python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev -y
fi

# Set OE_HOME and OE_HOME_EXT based on version
OE_BASE_DIR="/odoo"
OE_VERSION_SHORT="$OE_VERSION_INPUT"
OE_HOME="$OE_BASE_DIR/odoo$OE_VERSION_SHORT"
OE_HOME_EXT="$OE_HOME/${OE_USER}-server"
ENTERPRISE_ADDONS="${OE_HOME}/enterprise/addons"

# Gather existing instances
INSTANCE_CONFIG_FILES=(/etc/${OE_USER}-server-*.conf)
if [ -f "${INSTANCE_CONFIG_FILES[0]}" ]; then
    for CONFIG_FILE in "${INSTANCE_CONFIG_FILES[@]}"; do
        INSTANCE_NAME=$(basename "$CONFIG_FILE" | sed "s/${OE_USER}-server-//" | sed 's/\.conf//')
        CONFIG_VERSION=$(grep "^addons_path" "$CONFIG_FILE" | grep -o "odoo[0-9]*" | grep -o "[0-9]*")
        if [ "$CONFIG_VERSION" == "$OE_VERSION_SHORT" ]; then
            EXISTING_INSTANCE_NAMES+=("$INSTANCE_NAME")
            OE_PORT=$(grep "^xmlrpc_port" "$CONFIG_FILE" | awk -F '= ' '{print $2}')
            GEVENT_PORT=$(grep "^gevent_port" "$CONFIG_FILE" | awk -F '= ' '{print $2}')
            EXISTING_OE_PORTS+=("$OE_PORT")
            EXISTING_GEVENT_PORTS+=("$GEVENT_PORT")
        fi
    done
else
    echo "No existing Odoo instances found."
fi

# Function to find an available port
find_available_port() {
    local BASE_PORT=$1
    local -n EXISTING_PORTS=$2
    local PORT=$BASE_PORT
    while true; do
        # Check if the port is in use or in the list of existing ports
        if [[ " ${EXISTING_PORTS[@]} " =~ " $PORT " ]] || lsof -i TCP:$PORT >/dev/null 2>&1; then
            PORT=$((PORT + 1))
        else
            echo "$PORT"
            break
        fi
    done
}

# Prompt for instance name
read -p "Enter the name for the new instance (e.g., odoo1): " INSTANCE_NAME

# Validate instance name
if [[ ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid instance name. Only letters, numbers, underscores, and hyphens are allowed."
    exit 1
fi

# Function to create PostgreSQL user with random password
create_postgres_user() {
    local DB_USER=$1
    local DB_PASSWORD=$2

    # Check if PostgreSQL user already exists
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
        echo "PostgreSQL user '$DB_USER' already exists. Skipping creation."
    else
        # Create the database user
        sudo -u postgres psql -c "CREATE USER $DB_USER WITH CREATEDB NOSUPERUSER NOCREATEROLE PASSWORD '$DB_PASSWORD';"
        echo "PostgreSQL user '$DB_USER' created successfully."
    fi
}

# Prompt for enterprise license
read -p "Do you have an enterprise license for the database of this instance? You will have to enter your license code after installation (yes/no): " ENTERPRISE_CHOICE
if [[ "$ENTERPRISE_CHOICE" =~ ^(yes|y)$ ]]; then
    HAS_ENTERPRISE_LICENSE="True"
else
    HAS_ENTERPRISE_LICENSE="False"
fi

# Check if instance already exists
if [[ " ${EXISTING_INSTANCE_NAMES[@]} " =~ " ${INSTANCE_NAME} " ]]; then
    echo "An instance with the name '$INSTANCE_NAME' already exists. Please choose a different name."
    exit 1
fi

# Set OE_CONFIG for the instance
OE_CONFIG="${OE_USER}-server-${INSTANCE_NAME}"

# Find available ports
OE_PORT=$(find_available_port $BASE_ODOO_PORT EXISTING_OE_PORTS)
GEVENT_PORT=$(find_available_port $BASE_GEVENT_PORT EXISTING_GEVENT_PORTS)

echo "Assigned Ports:"
echo "  XML-RPC Port: $OE_PORT"
echo "  Gevent (WebSocket) Port: $GEVENT_PORT"

# Ask whether to enable SSL for this instance
read -p "Do you want to enable SSL with Certbot for instance '$INSTANCE_NAME'? (yes/no): " SSL_CHOICE
if [[ "$SSL_CHOICE" =~ ^(yes|y)$ ]]; then
    ENABLE_SSL="True"
    # Prompt for domain name and admin email
    read -p "Enter the domain name for the instance (e.g., odoo.mycompany.com): " WEBSITE_NAME
    read -p "Enter your email address for SSL certificate registration: " ADMIN_EMAIL

    # Validate domain name
    if [[ ! "$WEBSITE_NAME" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo "Invalid domain name."
        exit 1
    fi

    # Validate email
    if ! [[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "Invalid email address."
        exit 1
    fi
else
    ENABLE_SSL="False"
    # No SSL, so we won't prompt for domain name
    WEBSITE_NAME=$SERVER_IP
fi

# Generate OE_SUPERADMIN
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    OE_SUPERADMIN=$(generate_random_password)
    echo "Generated random superadmin password."
else
    read -s -p "Enter the superadmin password for the database: " OE_SUPERADMIN
    echo
fi

# Generate random password for PostgreSQL user
DB_PASSWORD=$(generate_random_password)
echo "Generated random PostgreSQL password."

# Create PostgreSQL user
create_postgres_user "$INSTANCE_NAME" "$DB_PASSWORD"

echo -e "\n==== Configuring ODOO Instance '$INSTANCE_NAME' ===="

# Create custom addons directory for the instance
INSTANCE_DIR="${OE_HOME}/${INSTANCE_NAME}"
sudo mkdir -p "${INSTANCE_DIR}/custom/addons"
sudo chown -R $OE_USER:$OE_USER "${INSTANCE_DIR}"

# Create a virtual environment for the instance using the appropriate Python version
INSTANCE_VENV="${INSTANCE_DIR}/venv"
echo "Creating a virtual environment for instance '$INSTANCE_NAME' using Python ${PYTHON_VERSION}..."
sudo -u $OE_USER python${PYTHON_VERSION} -m venv "$INSTANCE_VENV"
if [ $? -ne 0 ]; then
    echo "Failed to create virtual environment. Exiting."
    exit 1
fi

# Activate and install required dependencies using the appropriate Python version
echo "Installing Python dependencies in the virtual environment..."
sudo -u $OE_USER bash -c "source ${INSTANCE_VENV}/bin/activate && pip install --upgrade pip wheel && pip install -r ${OE_HOME_EXT}/requirements.txt"
if [ $? -ne 0 ]; then
    echo "Failed to install Python dependencies. Exiting."
    exit 1
fi

# Determine the addons_path based on the enterprise license choice
if [ "$HAS_ENTERPRISE_LICENSE" = "True" ]; then
    ADDONS_PATH="${OE_HOME_EXT}/addons,${INSTANCE_DIR}/custom/addons,${ENTERPRISE_ADDONS}"
else
    ADDONS_PATH="${OE_HOME_EXT}/addons,${INSTANCE_DIR}/custom/addons"
fi

echo -e "\n---- Creating server config file for instance '$INSTANCE_NAME' ----"
sudo bash -c "cat > /etc/${OE_CONFIG}.conf" <<EOF
[options]
admin_passwd = ${OE_SUPERADMIN}
db_host = localhost
db_user = ${INSTANCE_NAME}
db_password = ${DB_PASSWORD}
;list_db = False
xmlrpc_port = ${OE_PORT}
gevent_port = ${GEVENT_PORT}
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
addons_path=${ADDONS_PATH}
limit_memory_hard = 2677721600
limit_memory_soft = 1829145600
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
max_cron_threads = 1
workers = 2
EOF

if [ "$ENABLE_SSL" = "True" ]; then
    sudo bash -c "echo 'dbfilter = ^%h\$' >> /etc/${OE_CONFIG}.conf"
    sudo bash -c "echo 'proxy_mode = True' >> /etc/${OE_CONFIG}.conf"
fi

sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

# Create systemd service file for the instance
echo -e "\n---- Creating systemd service file for instance '$INSTANCE_NAME' ----"
SERVICE_FILE="${OE_CONFIG}.service"
sudo bash -c "cat > /etc/systemd/system/${SERVICE_FILE}" <<EOF
[Unit]
Description=Odoo Open Source ERP and CRM - Instance ${INSTANCE_NAME}
After=network.target

[Service]
Type=simple
SyslogIdentifier=${OE_CONFIG}
PermissionsStartOnly=true
User=${OE_USER}
Group=${OE_USER}
ExecStart=${INSTANCE_VENV}/bin/python ${OE_HOME_EXT}/odoo-bin -c /etc/${OE_CONFIG}.conf
WorkingDirectory=${OE_HOME_EXT}
StandardOutput=journal+console
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd daemon and start the service
echo -e "\n---- Starting ODOO service for instance '$INSTANCE_NAME' ----"
sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_FILE}
sudo systemctl start ${SERVICE_FILE}

# Check if the service started successfully
sudo systemctl is-active --quiet ${SERVICE_FILE}
if [ $? -ne 0 ]; then
    echo "Service ${SERVICE_FILE} failed to start. Please check the logs."
    sudo journalctl -u ${SERVICE_FILE} --no-pager
    exit 1
fi

echo "Odoo service for instance '$INSTANCE_NAME' started successfully."

#--------------------------------------------------
# Configure Nginx for this instance
#--------------------------------------------------
if [ "$ENABLE_SSL" = "True" ]; then
    echo -e "\n---- Configuring Nginx for instance '$INSTANCE_NAME' with SSL ----"

    NGINX_CONF_FILE="/etc/nginx/sites-available/${WEBSITE_NAME}"
    # Remove existing Nginx configuration if it exists
    if [ -f "$NGINX_CONF_FILE" ]; then
        echo "Existing Nginx configuration for '$WEBSITE_NAME' found. Removing it."
        sudo rm -f "$NGINX_CONF_FILE"
        sudo rm -f "/etc/nginx/sites-enabled/${WEBSITE_NAME}" || true
    fi

    # --------------------------------------------------
    # Step 1: Create Initial Nginx Configuration Without SSL
    # --------------------------------------------------
    echo -e "\n---- Configuring Nginx for instance '$INSTANCE_NAME' without SSL to obtain certificates ----"

    sudo bash -c "cat > /etc/nginx/sites-available/${WEBSITE_NAME}" <<EOF
# Odoo server - Initial configuration for SSL certificate generation
upstream odoo_${INSTANCE_NAME} {
  server 127.0.0.1:${OE_PORT};
}
upstream odoochat_${INSTANCE_NAME} {
  server 127.0.0.1:${GEVENT_PORT};
}
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

server {
  listen 80;
  server_name ${WEBSITE_NAME};

  access_log /var/log/nginx/${INSTANCE_NAME}.access.log;
  error_log /var/log/nginx/${INSTANCE_NAME}.error.log;

  location / {
    proxy_pass http://odoo_${INSTANCE_NAME};
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
  }

  location /websocket {
    proxy_pass http://odoochat_${INSTANCE_NAME};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  # Enable Gzip
  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
  gzip on;
}
EOF

    # Symlink the initial config to sites-enabled
    sudo ln -s "$NGINX_CONF_FILE" /etc/nginx/sites-enabled/${WEBSITE_NAME}

    echo "Initial Nginx configuration for instance '$INSTANCE_NAME' is created at $NGINX_CONF_FILE without SSL."

    # Test Nginx configuration
    sudo nginx -t
    if [ $? -ne 0 ]; then
        echo "Initial Nginx configuration test failed. Please check the configuration."
        exit 1
    fi

    # Restart Nginx to apply the initial configuration
    sudo systemctl restart nginx

    # --------------------------------------------------
    # Step 2: Obtain SSL Certificates Using Certbot
    # --------------------------------------------------
    echo -e "\n---- Setting up SSL certificates with Certbot ----"
    sudo certbot certonly --nginx -d $WEBSITE_NAME --non-interactive --agree-tos --email $ADMIN_EMAIL --redirect

    if [ $? -ne 0 ]; then
        echo "Certbot failed to obtain SSL certificates. Please check the domain and email address."
        exit 1
    fi

    echo "SSL certificates obtained successfully."

    # --------------------------------------------------
    # Step 3: Update Nginx Configuration to Include SSL
    # --------------------------------------------------
    echo -e "\n---- Updating Nginx configuration to include SSL ----"

    sudo bash -c "cat > /etc/nginx/sites-available/${WEBSITE_NAME}" <<EOF
# Odoo server - Configuration with SSL
upstream odoo_${INSTANCE_NAME} {
  server 127.0.0.1:${OE_PORT};
}
upstream odoochat_${INSTANCE_NAME} {
  server 127.0.0.1:${GEVENT_PORT};
}
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

# HTTP -> HTTPS redirect
server {
  listen 80;
  server_name ${WEBSITE_NAME};
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl;
  server_name ${WEBSITE_NAME};
  proxy_read_timeout 720s;
  proxy_connect_timeout 720s;
  proxy_send_timeout 720s;

  # SSL parameters
  ssl_certificate /etc/letsencrypt/live/${WEBSITE_NAME}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${WEBSITE_NAME}/privkey.pem;
  ssl_session_timeout 30m;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:\
ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:\
ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:\
DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
  ssl_prefer_server_ciphers off;

  # Logs
  access_log /var/log/nginx/${INSTANCE_NAME}.access.log;
  error_log /var/log/nginx/${INSTANCE_NAME}.error.log;

  # Redirect websocket requests to odoo gevent port
  location /websocket {
    proxy_pass http://odoochat_${INSTANCE_NAME};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    proxy_cookie_flags session_id samesite=lax secure;
  }

  # Redirect requests to odoo backend server
  location / {
    # Add Headers for odoo proxy mode
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
    proxy_pass http://odoo_${INSTANCE_NAME};

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    proxy_cookie_flags session_id samesite=lax secure;
  }

  # Enable Gzip
  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
  gzip on;
}
EOF

    # Test Nginx configuration
    sudo nginx -t
    if [ $? -ne 0 ]; then
        echo "Updated Nginx configuration with SSL test failed. Please check the configuration."
        exit 1
    fi

    # Restart Nginx to apply the updated configuration
    sudo systemctl restart nginx

    echo "Nginx configuration for instance '$INSTANCE_NAME' with SSL is up and running."

else
    echo "Nginx isn't configured for instance '$INSTANCE_NAME' due to user's choice of not enabling SSL."

    # Configure Nginx without SSL
    echo -e "\n---- Configuring Nginx for instance '$INSTANCE_NAME' without SSL ----"

    NGINX_CONF_FILE="/etc/nginx/sites-available/${INSTANCE_NAME}"
    # Remove existing Nginx configuration if it exists
    if [ -f "$NGINX_CONF_FILE" ]; then
        echo "Existing Nginx configuration for '$INSTANCE_NAME' found. Removing it."
        sudo rm -f "$NGINX_CONF_FILE"
        sudo rm -f "/etc/nginx/sites-enabled/${INSTANCE_NAME}" || true
    fi

    # Create Nginx configuration without SSL
    sudo bash -c "cat > /etc/nginx/sites-available/${INSTANCE_NAME}" <<EOF
# Odoo server
upstream odoo_${INSTANCE_NAME} {
  server 127.0.0.1:${OE_PORT};
}
upstream odoochat_${INSTANCE_NAME} {
  server 127.0.0.1:${GEVENT_PORT};
}
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

server {
  listen 80;
  server_name ${SERVER_IP};

  access_log /var/log/nginx/${INSTANCE_NAME}.access.log;
  error_log /var/log/nginx/${INSTANCE_NAME}.error.log;

  location / {
    proxy_pass http://odoo_${INSTANCE_NAME};
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
  }

  location /websocket {
    proxy_pass http://odoochat_${INSTANCE_NAME};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  # Enable Gzip
  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
  gzip on;
}
EOF

    # Symlink the config to sites-enabled
    sudo ln -s "$NGINX_CONF_FILE" /etc/nginx/sites-enabled/${INSTANCE_NAME}

    echo "Nginx configuration for instance '$INSTANCE_NAME' is created at $NGINX_CONF_FILE"

    # Test Nginx configuration
    sudo nginx -t
    if [ $? -ne 0 ]; then
        echo "Nginx configuration test failed. Please check the configuration."
        exit 1
    fi

    # Restart Nginx to apply the new configuration
    sudo systemctl restart nginx

    echo "Nginx configuration without SSL is up and running for instance '$INSTANCE_NAME'."
fi

echo "-----------------------------------------------------------"
echo "Instance '$INSTANCE_NAME' has been added successfully!"
echo "-----------------------------------------------------------"
echo "Ports:"
echo "  XML-RPC Port: $OE_PORT"
echo "  Gevent (WebSocket) Port: $GEVENT_PORT"
echo ""
echo "Service Information:"
echo "  Service Name: ${SERVICE_FILE}"
echo "  Configuration File: /etc/${OE_CONFIG}.conf"
echo "  Logfile: /var/log/${OE_USER}/${OE_CONFIG}.log"
echo ""
echo "Custom Addons Folder: ${INSTANCE_DIR}/custom/addons/"
echo ""
echo "Database Information:"
echo "  Database User: $INSTANCE_NAME"
echo "  Database Password: $DB_PASSWORD"
echo ""
echo "Superadmin Information:"
echo "  Superadmin Password: $OE_SUPERADMIN"
echo ""
echo "Manage Odoo service with the following commands:"
echo "  Start:   sudo systemctl start ${SERVICE_FILE}"
echo "  Stop:    sudo systemctl stop ${SERVICE_FILE}"
echo "  Restart: sudo systemctl restart ${SERVICE_FILE}"
echo ""
if [ "$ENABLE_SSL" = "True" ]; then
    echo "Nginx Configuration File: /etc/nginx/sites-available/${WEBSITE_NAME}"
    echo "Access URL: https://${WEBSITE_NAME}"
else
    echo "Nginx Configuration File: /etc/nginx/sites-available/${INSTANCE_NAME}"
    echo "Access URL: http://${SERVER_IP}:${OE_PORT}"
fi
echo "-----------------------------------------------------------"
