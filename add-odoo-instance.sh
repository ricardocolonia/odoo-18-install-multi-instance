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

# Function to generate a random password
generate_random_password() {
    openssl rand -base64 16
}

# Base variables
OE_USER="odoo"
INSTALL_WKHTMLTOPDF="True"
OE_VERSION="17.0"
IS_ENTERPRISE="False"
GENERATE_RANDOM_PASSWORD="True"
BASE_ODOO_PORT=8069
BASE_LONGPOLLING_PORT=9069

OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"
ENTERPRISE_ADDONS="$OE_HOME/enterprise/addons"

# Get server IP address
SERVER_IP=$(hostname -I | awk '{print $1}')

# Arrays to store existing instances and ports
declare -a EXISTING_INSTANCE_NAMES
declare -a EXISTING_OE_PORTS
declare -a EXISTING_LONGPOLLING_PORTS

# Gather existing instances
INSTANCE_CONFIG_FILES=(/etc/${OE_USER}-server-*.conf)
if [ -f "${INSTANCE_CONFIG_FILES[0]}" ]; then
    for CONFIG_FILE in "${INSTANCE_CONFIG_FILES[@]}"; do
        INSTANCE_NAME=$(basename "$CONFIG_FILE" | sed "s/${OE_USER}-server-//" | sed 's/\.conf//')
        EXISTING_INSTANCE_NAMES+=("$INSTANCE_NAME")
        OE_PORT=$(grep "^xmlrpc_port" "$CONFIG_FILE" | awk -F '= ' '{print $2}')
        LONGPOLLING_PORT=$(grep "^longpolling_port" "$CONFIG_FILE" | awk -F '= ' '{print $2}')
        EXISTING_OE_PORTS+=("$OE_PORT")
        EXISTING_LONGPOLLING_PORTS+=("$LONGPOLLING_PORT")
    done
else
    echo "No existing Odoo instances found."
fi

# Find available ports
find_available_port() {
    local BASE_PORT=$1
    local -n EXISTING_PORTS=$2
    local PORT=$BASE_PORT
    while true; do
        if [[ " ${EXISTING_PORTS[@]} " =~ " $PORT " ]]; then
            PORT=$((PORT + 1))
        else
            echo "$PORT"
            break
        fi
    done
}

# Prompt for instance name
read -p "Enter the name for the new instance (e.g., odoo1): " INSTANCE_NAME

# Function to create PostgreSQL user with random password
create_postgres_user() {
    local DB_USER=$INSTANCE_NAME
    local DB_PASSWORD=$2

    # Switch to postgres user to create the database user
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH CREATEDB NOSUPERUSER NOCREATEROLE PASSWORD '$DB_PASSWORD';"
}

# New prompt for enterprise license
read -p "Do you have an enterprise license for the database of this instance? You will have to enter your license code after installation (yes/no): " ENTERPRISE_CHOICE
if [ "$ENTERPRISE_CHOICE" == "yes" ]; then
    HAS_ENTERPRISE_LICENSE="True"
else
    HAS_ENTERPRISE_LICENSE="False"
fi

# Check if instance already exists
if [[ " ${EXISTING_INSTANCE_NAMES[@]} " =~ " ${INSTANCE_NAME} " ]]; then
    echo "An instance with the name $INSTANCE_NAME already exists."
    exit 1
fi

# Set OE_CONFIG for the instance
OE_CONFIG="${OE_USER}-server-${INSTANCE_NAME}"

# Find available ports
OE_PORT=$(find_available_port $BASE_ODOO_PORT EXISTING_OE_PORTS)
LONGPOLLING_PORT=$(find_available_port $BASE_LONGPOLLING_PORT EXISTING_LONGPOLLING_PORTS)

# Ask whether to enable SSL for this instance
read -p "Do you want to enable SSL with Certbot for instance $INSTANCE_NAME? (yes/no): " SSL_CHOICE
if [ "$SSL_CHOICE" == "yes" ]; then
    ENABLE_SSL="True"
    # Prompt for domain name and admin email
    read -p "Enter the domain name for the instance (e.g., odoo.mycompany.com): " WEBSITE_NAME
    read -p "Enter your email address for SSL certificate registration: " ADMIN_EMAIL
else
    ENABLE_SSL="False"
    # No SSL, so we won't prompt for domain name
    WEBSITE_NAME=$SERVER_IP
fi

# Generate OE_SUPERADMIN
if [ $GENERATE_RANDOM_PASSWORD = "True" ]; then
    OE_SUPERADMIN=$(generate_random_password)
else
    OE_SUPERADMIN="admin"
fi

# Generate random password for PostgreSQL user
DB_PASSWORD=$(generate_random_password)

# Call the function to create PostgreSQL user
create_postgres_user "$OE_USER" "$DB_PASSWORD"

echo -e "\n==== Configuring ODOO Instance $INSTANCE_NAME ===="

# Create custom addons directory for the instance
INSTANCE_DIR="$OE_HOME/$INSTANCE_NAME"
sudo mkdir -p $INSTANCE_DIR/custom/addons
sudo chown -R $OE_USER:$OE_USER $INSTANCE_DIR

# Determine the addons_path based on the enterprise license choice
if [ "${HAS_ENTERPRISE_LICENSE[$i]}" == "True" ]; then
    ADDONS_PATH="${OE_HOME_EXT}/addons,${INSTANCE_DIR}/custom/addons,${ENTERPRISE_ADDONS}"
else
    ADDONS_PATH="${OE_HOME_EXT}/addons,${INSTANCE_DIR}/custom/addons"
fi

echo -e "\n---- Creating server config file for instance $INSTANCE_NAME ----"
sudo sh -c "cat > /etc/${OE_CONFIG}.conf" <<EOF
[options]
admin_passwd = ${OE_SUPERADMIN}
db_host = localhost
db_user = $INSTANCE_NAME
db_password = ${DB_PASSWORD}
;list_db = False
xmlrpc_port = ${OE_PORT}
gevent_port = ${LONGPOLLING_PORT}
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
addons_path=${ADDONS_PATH}
limit_memory_hard = 1677721600
limit_memory_soft = 629145600
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
max_cron_threads = 1
workers = 2
EOF

if [ $ENABLE_SSL = "True" ]; then
    sudo sh -c "echo 'dbfilter = ^%h\$' >> /etc/${OE_CONFIG}.conf"
    sudo sh -c "echo 'proxy_mode = True' >> /etc/${OE_CONFIG}.conf"
fi

sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

# Create systemd service file for the instance
echo -e "* Creating systemd service file for instance $INSTANCE_NAME"
cat <<EOF > ~/${OE_CONFIG}.service
[Unit]
Description=Odoo Open Source ERP and CRM - Instance ${INSTANCE_NAME}
After=network.target

[Service]
Type=simple
SyslogIdentifier=${OE_CONFIG}
PermissionsStartOnly=true
User=${OE_USER}
Group=${OE_USER}
ExecStart=${OE_HOME}/venv/bin/python ${OE_HOME_EXT}/odoo-bin -c /etc/${OE_CONFIG}.conf
WorkingDirectory=${OE_HOME_EXT}
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF

sudo mv ~/${OE_CONFIG}.service /etc/systemd/system/${OE_CONFIG}.service
sudo chmod 644 /etc/systemd/system/${OE_CONFIG}.service
sudo chown root: /etc/systemd/system/${OE_CONFIG}.service

echo -e "* Starting ODOO service for instance $INSTANCE_NAME"
sudo systemctl daemon-reload
sudo systemctl enable ${OE_CONFIG}.service
sudo systemctl start ${OE_CONFIG}.service

# Check if the service started successfully
sudo systemctl is-active --quiet ${OE_CONFIG}.service
if [ $? -ne 0 ]; then
    echo "Service ${OE_CONFIG}.service failed to start. Please check the logs."
    sudo journalctl -u ${OE_CONFIG}.service --no-pager
    exit 1
fi

#--------------------------------------------------
# Configure Nginx for this instance
#--------------------------------------------------
if [ $ENABLE_SSL = "True" ]; then
    echo -e "\n---- Configuring Nginx for instance $INSTANCE_NAME ----"
    sudo apt install nginx -y

    NGINX_CONF_FILE="/etc/nginx/sites-available/${WEBSITE_NAME}"
    # Remove existing Nginx configuration if it exists
    if [ -f "$NGINX_CONF_FILE" ]; then
        echo "Existing Nginx configuration for $WEBSITE_NAME found. Removing it."
        sudo rm -f "$NGINX_CONF_FILE"
        sudo rm -f "/etc/nginx/sites-enabled/${WEBSITE_NAME}"
    fi

    # Create initial Nginx configuration without SSL
    cat <<EOF > ~/${WEBSITE_NAME}
# Odoo server
upstream odoo_${INSTANCE_NAME} {
  server 127.0.0.1:${OE_PORT};
}
upstream odoochat_${INSTANCE_NAME} {
  server 127.0.0.1:${LONGPOLLING_PORT};
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

  proxy_read_timeout 720s;
  proxy_connect_timeout 720s;
  proxy_send_timeout 720s;

  # Redirect websocket requests to odoo longpolling port
  location /websocket {
    proxy_pass http://odoochat_${INSTANCE_NAME};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  # Redirect requests to odoo backend server
  location / {
    proxy_pass http://odoo_${INSTANCE_NAME};
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
  }

  # Gzip settings
  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
  gzip on;
}
EOF

    sudo mv ~/${WEBSITE_NAME} $NGINX_CONF_FILE
    sudo ln -s $NGINX_CONF_FILE /etc/nginx/sites-enabled/${WEBSITE_NAME}

    echo "Nginx configuration for instance $INSTANCE_NAME is created at $NGINX_CONF_FILE"

    # Test Nginx configuration
    sudo nginx -t
    if [ $? -ne 0 ]; then
        echo "Nginx configuration test failed. Please check the configuration."
        exit 1
    fi

    # Restart Nginx
    sudo systemctl restart nginx

    #--------------------------------------------------
    # Enable SSL with Certbot
    #--------------------------------------------------
    echo -e "\n---- Setting up SSL certificates ----"
    sudo apt-get update -y
    sudo apt install snapd -y
    sudo snap install core; sudo snap refresh core
    sudo snap install --classic certbot
    sudo ln -sf /snap/bin/certbot /usr/bin/certbot

    # Obtain SSL certificates
    sudo certbot certonly --nginx -d $WEBSITE_NAME --non-interactive --agree-tos --email $ADMIN_EMAIL

    # Create Nginx configuration with SSL
    cat <<EOF > ~/${WEBSITE_NAME}
# Odoo server
upstream odoo_${INSTANCE_NAME} {
  server 127.0.0.1:${OE_PORT};
}
upstream odoochat_${INSTANCE_NAME} {
  server 127.0.0.1:${LONGPOLLING_PORT};
}
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

# Redirect all HTTP traffic to HTTPS
server {
  listen 80;
  server_name ${WEBSITE_NAME};

  return 301 https://\$host\$request_uri;
}

# Handle HTTPS traffic
server {
  listen 443 ssl;
  server_name ${WEBSITE_NAME};

  ssl_certificate /etc/letsencrypt/live/${WEBSITE_NAME}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${WEBSITE_NAME}/privkey.pem;
  ssl_session_timeout 30m;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:\
ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:\
ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:\
DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
  ssl_prefer_server_ciphers off;

  access_log /var/log/nginx/${INSTANCE_NAME}.access.log;
  error_log /var/log/nginx/${INSTANCE_NAME}.error.log;

  proxy_read_timeout 720s;
  proxy_connect_timeout 720s;
  proxy_send_timeout 720s;

  # Redirect websocket requests to odoo longpolling port
  location /longpolling {
    proxy_pass http://odoochat_${INSTANCE_NAME};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    proxy_cookie_flags session_id samesite=lax secure;
  }

  # Redirect requests to Odoo backend server
  location / {
    proxy_pass http://odoo_${INSTANCE_NAME};
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    proxy_cookie_flags session_id samesite=lax secure;
  }

  # Gzip settings
  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
  gzip on;
}
EOF

    sudo mv ~/${WEBSITE_NAME} $NGINX_CONF_FILE

    # Test Nginx configuration
    sudo nginx -t
    if [ $? -ne 0 ]; then
        echo "Nginx configuration test failed after adding SSL. Please check the configuration."
        exit 1
    fi

    # Reload Nginx
    sudo systemctl reload nginx

    echo "Done! The Nginx server is up and running with SSL for instance $INSTANCE_NAME."

else
    echo "Nginx isn't configured for instance $INSTANCE_NAME due to choice of the user!"
fi

echo "-----------------------------------------------------------"
echo "Instance $INSTANCE_NAME has been added successfully!"
echo "Port: $OE_PORT"
echo "Gevent Port: $LONGPOLLING_PORT"
echo "User service: $INSTANCE_NAME"
echo "Configuration file location: /etc/${OE_CONFIG}.conf"
echo "Logfile location: /var/log/$OE_USER/${OE_CONFIG}.log"
echo "Custom addons folder: $OE_HOME/$INSTANCE_NAME/custom/addons/"
echo "Password superadmin (database): $OE_SUPERADMIN"
echo "Start Odoo service: sudo systemctl start ${OE_CONFIG}.service"
echo "Stop Odoo service: sudo systemctl stop ${OE_CONFIG}.service"
echo "Restart Odoo service: sudo systemctl restart ${OE_CONFIG}.service"

if [ $ENABLE_SSL = "True" ]; then
    echo "Nginx configuration file: /etc/nginx/sites-available/${WEBSITE_NAME}"
    echo "Access URL: https://${WEBSITE_NAME}"
else
    echo "Access URL: http://${SERVER_IP}:${OE_PORT}"
fi
echo "-----------------------------------------------------------"
