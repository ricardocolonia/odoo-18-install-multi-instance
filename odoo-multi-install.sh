#!/bin/bash
################################################################################
# Script for installing multiple Odoo instances on Ubuntu
# Author: Based on script by Yenthe Van Ginneken, modified for multiple instances
#-------------------------------------------------------------------------------
# This script will install multiple Odoo instances on your Ubuntu server.
# It will prompt for the data needed for each instance.
#-------------------------------------------------------------------------------
# To use this script:
# 1. Save it as odoo-multi-install.sh
#    sudo nano odoo-multi-install.sh
# 2. Make the script executable:
#    sudo chmod +x odoo-multi-install.sh
# 3. Run the script:
#    sudo ./odoo-multi-install.sh
################################################################################

# Function to generate a random password
generate_random_password() {
    openssl rand -base64 16
}

# Function to create PostgreSQL user with random password
create_postgres_user() {
    local DB_USER=$1
    local DB_PASSWORD=$2

    # Check if the user already exists
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
        echo "PostgreSQL user $DB_USER already exists."
    else
        # Create the user
        sudo -u postgres psql -c "CREATE USER $DB_USER WITH CREATEDB NOSUPERUSER NOCREATEROLE PASSWORD '$DB_PASSWORD';"
    fi
}

# Base variables
OE_USER="odoo"
INSTALL_WKHTMLTOPDF="True"
OE_VERSION="17.0"
IS_ENTERPRISE="False"
INSTALL_POSTGRESQL_FOURTEEN="True"
GENERATE_RANDOM_PASSWORD="True"

# Get server IP address
SERVER_IP=$(hostname -I | awk '{print $1}')

# Prompt for the number of instances
read -p "Enter the number of Odoo instances to install: " INSTANCE_COUNT

# Arrays to store per-instance variables
declare -a INSTANCE_NAMES
declare -a OE_CONFIGS
declare -a OE_PORTS
declare -a LONGPOLLING_PORTS
declare -a WEBSITE_NAMES
declare -a OE_SUPERADMINS
declare -a ENABLE_SSLS
declare -a DB_PASSWORDS
declare -a HAS_ENTERPRISE_LICENSE

# Base directories
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"

# Start from base ports
BASE_ODOO_PORT=8069
BASE_LONGPOLLING_PORT=9069

# Prompt for data for each instance
for ((i=1; i<=INSTANCE_COUNT; i++)); do
    echo "Configuring instance $i:"
    read -p "Enter the name for instance $i (e.g., odoo1): " INSTANCE_NAME
    INSTANCE_NAMES[$i]=$INSTANCE_NAME
    # Ask whether the user has an enterprise license for this instance
    read -p "Do you have an enterprise license for the database of this instance? You will have to enter your license code after installation (yes/no): " ENTERPRISE_CHOICE
    if [ "$ENTERPRISE_CHOICE" == "yes" ]; then
        HAS_ENTERPRISE_LICENSE[$i]="True"
    else
        HAS_ENTERPRISE_LICENSE[$i]="False"
    fi
    # Set OE_PORT and LONGPOLLING_PORT per instance
    OE_PORTS[$i]=$((BASE_ODOO_PORT + i - 1))
    LONGPOLLING_PORTS[$i]=$((BASE_LONGPOLLING_PORT + i - 1))

    # Set OE_CONFIG per instance
    OE_CONFIGS[$i]="${OE_USER}-server-${INSTANCE_NAME}"

    # Ask whether to enable SSL for this instance
    read -p "Do you want to enable SSL with Certbot for instance $INSTANCE_NAME? (yes/no): " SSL_CHOICE
    if [ "$SSL_CHOICE" == "yes" ]; then
        ENABLE_SSL="True"
        ENABLE_SSLS[$i]="True"
        # Prompt for domain name and admin email
        read -p "Enter the domain name for instance $i (e.g., odoo.mycompany.com): " WEBSITE_NAME
        read -p "Enter your email address for SSL certificate registration: " ADMIN_EMAIL
    else
        ENABLE_SSL="False"
        ENABLE_SSLS[$i]="False"
        # No SSL, so we won't prompt for domain name
        WEBSITE_NAME=$SERVER_IP
    fi
    WEBSITE_NAMES[$i]=$WEBSITE_NAME

    # Generate OE_SUPERADMIN per instance
    if [ $GENERATE_RANDOM_PASSWORD = "True" ]; then
        OE_SUPERADMIN=$(generate_random_password)
    else
        OE_SUPERADMIN="admin"
    fi
    OE_SUPERADMINS[$i]=$OE_SUPERADMIN

    # Generate DB_PASSWORD per instance
    DB_PASSWORD=$(generate_random_password)
    DB_PASSWORDS[$i]=$DB_PASSWORD

    # Call the function to create PostgreSQL user for this instance
    create_postgres_user $INSTANCE_NAME $DB_PASSWORD

done

#--------------------------------------------------
# Update Server and Install Dependencies
#--------------------------------------------------
echo -e "\n---- Update Server and Install Dependencies ----"
sudo apt-get update
sudo apt-get upgrade -y

# Install build tools and development libraries
sudo apt-get install build-essential -y
sudo apt-get install libxml2-dev libxslt1-dev zlib1g-dev -y
sudo apt-get install libsasl2-dev libldap2-dev libssl-dev -y
sudo apt-get install libpq-dev -y

# Install Python 3 and development headers
sudo apt-get install python3 python3-venv python3-dev -y

# Use the default Python 3 version
PYTHON_BIN=$(which python3)

# Verify Python installation
if [ -z "$PYTHON_BIN" ]; then
    echo "Python 3 is not installed. Exiting."
    exit 1
fi

echo "Using Python at $PYTHON_BIN"

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL Server ----"
if [ $INSTALL_POSTGRESQL_FOURTEEN = "True" ]; then
    echo -e "\n---- Installing PostgreSQL V14 ----"
    sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    sudo apt-get update
    sudo apt-get install postgresql-16 -y
else
    echo -e "\n---- Installing the default PostgreSQL version ----"
    sudo apt-get install postgresql postgresql-server-dev-all -y
fi

#--------------------------------------------------
# Create ODOO system user
#--------------------------------------------------
echo -e "\n---- Creating ODOO system user ----"
if id "$OE_USER" >/dev/null 2>&1; then
    echo "User $OE_USER already exists."
else
    sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER
    # For security reasons, do not add the odoo user to sudo group
fi

#--------------------------------------------------
# Install ODOO
#--------------------------------------------------
echo -e "\n==== Installing ODOO Server ===="
sudo mkdir -p $OE_HOME
sudo chown -R $OE_USER:$OE_USER $OE_HOME

echo -e "\n---- Creating Log directory ----"
sudo mkdir -p /var/log/$OE_USER
sudo chown $OE_USER:$OE_USER /var/log/$OE_USER

echo -e "\n---- Cloning Odoo source code ----"
echo "OE_HOME_EXT is set to '$OE_HOME_EXT'"
if [ ! -d "$OE_HOME_EXT" ]; then
    echo "Directory $OE_HOME_EXT does not exist, proceeding to clone Odoo source code."
    sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME_EXT/
    sudo chown -R $OE_USER:$OE_USER $OE_HOME_EXT/
else
    echo "Odoo source code already exists at $OE_HOME_EXT"
fi

echo -e "\n---- Creating Enterprise addons directory ----"
ENTERPRISE_ADDONS="$OE_HOME/enterprise/addons"
sudo mkdir -p $ENTERPRISE_ADDONS
sudo chown -R $OE_USER:$OE_USER $OE_HOME/enterprise

echo -e "\n---- Creating virtual environment ----"
if [ ! -d "$OE_HOME/venv" ]; then
    sudo -u $OE_USER $PYTHON_BIN -m venv $OE_HOME/venv
    if [ $? -ne 0 ]; then
        echo "Failed to create virtual environment. Exiting."
        exit 1
    fi
else
    echo "Virtual environment already exists at $OE_HOME/venv"
fi

echo -e "\n---- Installing Python requirements ----"
sudo -u $OE_USER $OE_HOME/venv/bin/pip install --upgrade pip
sudo -u $OE_USER $OE_HOME/venv/bin/pip install wheel

# Install dependencies that support Python 3.12
sudo -u $OE_USER $OE_HOME/venv/bin/pip install psycopg2-binary
sudo -u $OE_USER $OE_HOME/venv/bin/pip install -r $OE_HOME_EXT/requirements.txt

if [ $? -ne 0 ]; then
    echo "Failed to install Python requirements. Exiting."
    exit 1
fi

echo -e "\n---- Installing Node.js NPM and rtlcss for LTR support ----"
sudo apt-get install nodejs npm -y
sudo npm install -g rtlcss

#--------------------------------------------------
# Install Wkhtmltopdf if needed
#--------------------------------------------------
if [ $INSTALL_WKHTMLTOPDF = "True" ]; then
  echo -e "\n---- Installing wkhtmltopdf ----"
  sudo apt install wkhtmltopdf -y
else
  echo "Wkhtmltopdf isn't installed due to the choice of the user!"
fi

#--------------------------------------------------
# Install ODOO Instances
#--------------------------------------------------
for ((i=1; i<=INSTANCE_COUNT; i++)); do
    INSTANCE_NAME=${INSTANCE_NAMES[$i]}
    OE_PORT=${OE_PORTS[$i]}
    LONGPOLLING_PORT=${LONGPOLLING_PORTS[$i]}
    OE_CONFIG=${OE_CONFIGS[$i]}
    OE_SUPERADMIN=${OE_SUPERADMINS[$i]}
    WEBSITE_NAME=${WEBSITE_NAMES[$i]}
    ENABLE_SSL=${ENABLE_SSLS[$i]}
    DB_PASSWORD=${DB_PASSWORDS[$i]}
    HAS_ENTERPRISE=${HAS_ENTERPRISE_LICENSE[$i]}

    echo -e "\n==== Configuring ODOO Instance $INSTANCE_NAME ===="

    # Create custom addons directory for the instance
    INSTANCE_DIR="$OE_HOME/$INSTANCE_NAME"
    sudo mkdir -p $INSTANCE_DIR/custom/addons
    sudo chown -R $OE_USER:$OE_USER $INSTANCE_DIR

    # Determine the addons_path based on the enterprise license choice
    if [ "$HAS_ENTERPRISE" == "True" ]; then
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
gevent-port = ${LONGPOLLING_PORT}
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
addons_path=${ADDONS_PATH}
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
  location /longpolling {
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

        # Remove default nginx site if it's the first SSL-enabled instance
        if [ $i -eq 1 ]; then
            sudo rm /etc/nginx/sites-enabled/default
        fi

        echo "Nginx configuration for instance $INSTANCE_NAME is created at $NGINX_CONF_FILE"

        # Test Nginx configuration
        sudo nginx -t
        if [ $? -ne 0 ]; then
            echo "Nginx configuration test failed. Please check the configuration."
            exit 1
        fi

        # Restart Nginx
        sudo systemctl restart nginx

    else
        echo "Nginx isn't configured for instance $INSTANCE_NAME due to choice of the user!"
    fi

done # End of instance loop

# Global Nginx installation flag
NGINX_INSTALLED="False"
for ((i=1; i<=INSTANCE_COUNT; i++)); do
    if [ ${ENABLE_SSLS[$i]} = "True" ]; then
        NGINX_INSTALLED="True"
        break
    fi
done

if [ $NGINX_INSTALLED = "True" ]; then

    #--------------------------------------------------
    # Enable SSL with Certbot per instance
    #--------------------------------------------------
    echo -e "\n---- Setting up SSL certificates ----"
    sudo apt-get update -y
    sudo apt install snapd -y
    sudo snap install core; sudo snap refresh core
    sudo snap install --classic certbot
    sudo ln -sf /snap/bin/certbot /usr/bin/certbot

    for ((i=1; i<=INSTANCE_COUNT; i++)); do
        INSTANCE_NAME=${INSTANCE_NAMES[$i]}
        OE_PORT=${OE_PORTS[$i]}
        LONGPOLLING_PORT=${LONGPOLLING_PORTS[$i]}
        WEBSITE_NAME=${WEBSITE_NAMES[$i]}
        ENABLE_SSL=${ENABLE_SSLS[$i]}

        if [ "$ENABLE_SSL" = "True" ]; then
            # Obtain SSL certificates
            sudo certbot certonly --nginx -d $WEBSITE_NAME --non-interactive --agree-tos --email $ADMIN_EMAIL

            # Create Nginx configuration with SSL
            NGINX_CONF_FILE="/etc/nginx/sites-available/${WEBSITE_NAME}"

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

        else
            echo "SSL/HTTPS isn't enabled for instance $INSTANCE_NAME due to choice of the user!"
        fi
    done

    echo "Done! The Nginx server is up and running with SSL for enabled instances."
fi

echo "-----------------------------------------------------------"
echo "Done! The Odoo instances are up and running. Specifications:"
for ((i=1; i<=INSTANCE_COUNT; i++)); do
    INSTANCE_NAME=${INSTANCE_NAMES[$i]}
    OE_PORT=${OE_PORTS[$i]}
    LONGPOLLING_PORT=${LONGPOLLING_PORTS[$i]}
    OE_CONFIG=${OE_CONFIGS[$i]}
    OE_SUPERADMIN=${OE_SUPERADMINS[$i]}
    WEBSITE_NAME=${WEBSITE_NAMES[$i]}
    ENABLE_SSL=${ENABLE_SSLS[$i]}
    DB_PASSWORD=${DB_PASSWORDS[$i]}

    echo "-----------------------------------------------------------"
    echo "Instance $INSTANCE_NAME:"
    echo "Port: $OE_PORT"
    echo "Gevent Port: $LONGPOLLING_PORT"
    echo "Configuration file location: /etc/${OE_CONFIG}.conf"
    echo "Logfile location: /var/log/$OE_USER/${OE_CONFIG}.log"
    echo "Database user: $INSTANCE_NAME"
    echo "Database password: ${DB_PASSWORD}"
    echo "Code location: $OE_HOME_EXT"
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
done
echo "-----------------------------------------------------------"
