#!/bin/bash
################################################################################
# Script for installing Odoo on Ubuntu 16.04, 18.04, 20.04 and 22.04 (could be used for other version too)
# Author: Yenthe Van Ginneken
#-------------------------------------------------------------------------------
# This script will install Odoo on your Ubuntu server. It can install multiple Odoo instances
# in one Ubuntu because of the different xmlrpc_ports
#-------------------------------------------------------------------------------
# Make a new file:
# sudo nano odoo-install.sh
# Place this content in it and then make the file executable:
# sudo chmod +x odoo-install.sh
# Execute the script to install Odoo:
# ./odoo-install
################################################################################

# Updated variables for Odoo 18
OE_USER="odoo"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"
INSTALL_WKHTMLTOPDF="True"
OE_PORT="8069"
OE_VERSION="18.0"
IS_ENTERPRISE="True"
INSTALL_POSTGRESQL_SIXTEEN="True"
INSTALL_NGINX="False"
OE_SUPERADMIN="admin"
GENERATE_RANDOM_PASSWORD="True"
OE_CONFIG="${OE_USER}-server"
WEBSITE_NAME="_"
LONGPOLLING_PORT="8072"
ENABLE_SSL="False"
ADMIN_EMAIL="odoo@example.com"

# Add log file configuration
INSTALL_LOG_FILE="/var/log/odoo_install.log"
ERROR_LOG_FILE="/var/log/odoo_install_error.log"

# Function to log messages
log_message() {
    local message=$1
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $message" | tee -a $INSTALL_LOG_FILE
}

# Function to handle errors
handle_error() {
    local error_message=$1
    local error_code=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - ERROR: $error_message (Exit Code: $error_code)" | tee -a $ERROR_LOG_FILE
}

# Set error handling
set -e
trap 'handle_error "Command failed" $?' ERR

# Create log files
sudo touch $INSTALL_LOG_FILE $ERROR_LOG_FILE
sudo chmod 666 $INSTALL_LOG_FILE $ERROR_LOG_FILE

log_message "Starting Odoo 18 installation..."

# Check if the operating system is Ubuntu 22.04
if [[ $(lsb_release -r -s) == "22.04" ]]; then
    WKHTMLTOX_X64="https://packages.ubuntu.com/jammy/wkhtmltopdf"
    WKHTMLTOX_X32="https://packages.ubuntu.com/jammy/wkhtmltopdf"
    #No Same link works for both 64 and 32-bit on Ubuntu 22.04
else
    # For older versions of Ubuntu
    WKHTMLTOX_X64="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_amd64.deb"
    WKHTMLTOX_X32="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_i386.deb"
fi

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n---- Update Server ----"
log_message "Updating server..."
{
    sudo apt-get update
    sudo apt-get upgrade -y
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL Server ----"
log_message "Installing PostgreSQL..."
if [ $INSTALL_POSTGRESQL_SIXTEEN = "True" ]; then
    {
        echo -e "\n---- Installing PostgreSQL 16 ----"
        sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
        sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
        sudo apt-get update
        sudo apt-get install postgresql-16 -y
    } >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
        handle_error "PostgreSQL 16 installation failed" $?
        exit 1
    }
else
    echo -e "\n---- Installing default PostgreSQL version ----"
    sudo apt-get install postgresql postgresql-server-dev-all -y
fi

echo -e "\n---- Creating the ODOO PostgreSQL User  ----"
sudo su - postgres -c "createuser -s $OE_USER" 2> /dev/null || true

#--------------------------------------------------
# Create ODOO system user first
#--------------------------------------------------
echo -e "\n---- Create ODOO system user ----"
log_message "Creating ODOO system user..."
{
    if id "$OE_USER" &>/dev/null; then
        echo "User $OE_USER already exists"
    else
        sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER
        sudo adduser $OE_USER sudo
    fi

    # Create necessary directories and set permissions
    sudo mkdir -p $OE_HOME
    sudo mkdir -p /var/log/$OE_USER
    sudo chown -R $OE_USER:$OE_USER $OE_HOME
    sudo chown -R $OE_USER:$OE_USER /var/log/$OE_USER
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "ODOO system user creation failed" $?
    exit 1
}

#--------------------------------------------------
# Install Dependencies
#--------------------------------------------------
echo -e "\n--- Installing Python 3.12 + dependencies --"
log_message "Installing Python 3.12 and dependencies..."
{
    # Add deadsnakes PPA for Python 3.12
    sudo add-apt-repository ppa:deadsnakes/ppa -y
    sudo apt-get update
    sudo apt-get install python3.12 python3.12-dev python3.12-venv python3-full -y

    # Install pip properly
    sudo python3.12 -m ensurepip
    sudo python3.12 -m pip install --upgrade pip

    # Install other dependencies
    sudo apt-get install git build-essential wget pkg-config libxslt-dev libzip-dev \
        libldap2-dev libsasl2-dev libssl-dev libpq-dev libjpeg-dev gdebi \
        xfonts-75dpi xfonts-base libxml2-dev nodejs npm -y
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "Python 3.12 and dependencies installation failed" $?
    exit 1
}

echo -e "\n---- Install python packages/requirements ----"
log_message "Installing python packages/requirements..."
{
    # Create and setup virtual environment
    sudo -u $OE_USER python3.12 -m venv $OE_HOME/venv
    
    # Install packages in virtual environment
    sudo -u $OE_USER $OE_HOME/venv/bin/pip install --upgrade pip wheel

    # Install Odoo requirements
    sudo -u $OE_USER $OE_HOME/venv/bin/pip install -r https://raw.githubusercontent.com/odoo/odoo/18.0/requirements.txt

    # Install additional dependencies needed for Odoo 18
    sudo -u $OE_USER $OE_HOME/venv/bin/pip install psycopg2-binary python-ldap
    sudo -u $OE_USER $OE_HOME/venv/bin/pip install Babel decorator docutils ebaysdk gevent greenlet html2text Jinja2 libsass lxml
    sudo -u $OE_USER $OE_HOME/venv/bin/pip install python-dateutil pytz pyusb PyYAML qrcode reportlab requests werkzeug
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "Python packages installation failed" $?
    exit 1
}

echo -e "\n---- Installing nodeJS NPM and rtlcss for LTR support ----"
log_message "Installing nodeJS NPM and rtlcss..."
{
    sudo npm install -g rtlcss
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "nodeJS NPM and rtlcss installation failed" $?
    exit 1
}

#--------------------------------------------------
# Install Wkhtmltopdf if needed
#--------------------------------------------------
if [ $INSTALL_WKHTMLTOPDF = "True" ]; then
    echo -e "\n---- Install wkhtmltopdf ----"
    log_message "Installing wkhtmltopdf..."
    if [[ $(lsb_release -r -s) == "22.04" ]] || [[ $(lsb_release -r -s) == "24.04" ]]; then
        {
            sudo apt-get install wkhtmltopdf -y
        } >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
            handle_error "wkhtmltopdf installation failed" $?
            exit 1
        }
    else
        {
            WKHTMLTOX_VERSION="0.12.6.1-2"
            WKHTMLTOX_HASH="db48fa1a043309c4bfe8c8e0e38dc06c183f821599dd88d4e3cea47b5a48d85e"
            wget "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOX_VERSION}/wkhtmltox_${WKHTMLTOX_VERSION}.jammy_amd64.deb"
            echo "${WKHTMLTOX_HASH} wkhtmltox_${WKHTMLTOX_VERSION}.jammy_amd64.deb" | sha256sum -c -
            sudo apt-get install -y ./wkhtmltox_${WKHTMLTOX_VERSION}.jammy_amd64.deb
            rm wkhtmltox_${WKHTMLTOX_VERSION}.jammy_amd64.deb
        } >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
            handle_error "wkhtmltopdf installation failed" $?
            exit 1
        }
    fi
fi

echo -e "\n---- Create ODOO system user ----"
log_message "Creating ODOO system user..."
{
    if id "$OE_USER" &>/dev/null; then
        echo "User $OE_USER already exists"
    else
        sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER
        sudo adduser $OE_USER sudo
    fi
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "ODOO system user creation failed" $?
    exit 1
}

echo -e "\n---- Create Log directory ----"
log_message "Creating log directory..."
{
    sudo mkdir -p /var/log/$OE_USER
    sudo chown $OE_USER:$OE_USER /var/log/$OE_USER
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "Log directory creation failed" $?
    exit 1
}

#--------------------------------------------------
# Install ODOO
#--------------------------------------------------
echo -e "\n==== Installing ODOO Server ===="
log_message "Installing ODOO Server..."
{
    if [ ! -d "$OE_HOME_EXT" ]; then
        sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME_EXT/
        sudo chown -R $OE_USER:$OE_USER $OE_HOME_EXT/
    else
        echo "Odoo directory $OE_HOME_EXT already exists."
    fi
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "ODOO Server installation failed" $?
    exit 1
}

if [ $IS_ENTERPRISE = "True" ]; then
    # Odoo Enterprise install!
    log_message "Installing Odoo Enterprise..."
    {
        sudo pip3 install psycopg2-binary pdfminer.six
        echo -e "\n--- Create symlink for node"
        sudo ln -s /usr/bin/nodejs /usr/bin/node
        sudo su $OE_USER -c "mkdir $OE_HOME/enterprise"
        sudo su $OE_USER -c "mkdir $OE_HOME/enterprise/addons"

        GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
        while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
            echo "------------------------WARNING------------------------------"
            echo "Your authentication with Github has failed! Please try again."
            printf "In order to clone and install the Odoo enterprise version you \nneed to be an offical Odoo partner and you need access to\nhttp://github.com/odoo/enterprise.\n"
            echo "TIP: Press ctrl+c to stop this script."
            echo "-------------------------------------------------------------"
            echo " "
            GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
        done

        echo -e "\n---- Added Enterprise code under $OE_HOME/enterprise/addons ----"
        echo -e "\n---- Installing Enterprise specific libraries ----"
        sudo -H pip3 install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
        sudo npm install -g less
        sudo npm install -g less-plugin-clean-css
    } >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
        handle_error "Odoo Enterprise installation failed" $?
        exit 1
    }
fi

echo -e "\n---- Create custom module directory ----"
log_message "Creating custom module directory..."
{
    sudo su $OE_USER -c "mkdir $OE_HOME/custom"
    sudo su $OE_USER -c "mkdir $OE_HOME/custom/addons"
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "Custom module directory creation failed" $?
    exit 1
}

echo -e "\n---- Setting permissions on home folder ----"
log_message "Setting permissions on home folder..."
{
    sudo chown -R $OE_USER:$OE_USER $OE_HOME/*
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "Setting permissions on home folder failed" $?
    exit 1
}

echo -e "* Create server config file"
log_message "Creating server config file..."
{
    sudo touch /etc/${OE_CONFIG}.conf
    echo -e "* Creating server config file"
    sudo su root -c "printf '[options] \n; This is the password that allows database operations:\n' >> /etc/${OE_CONFIG}.conf"
    if [ $GENERATE_RANDOM_PASSWORD = "True" ]; then
        echo -e "* Generating random admin password"
        OE_SUPERADMIN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
    fi
    sudo su root -c "printf 'admin_passwd = ${OE_SUPERADMIN}\n' >> /etc/${OE_CONFIG}.conf"
    sudo su root -c "printf 'http_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
    sudo su root -c "printf 'logfile = /var/log/${OE_USER}/${OE_CONFIG}.log\n' >> /etc/${OE_CONFIG}.conf"

    # Add Python 3.12 specific settings
    sudo su root -c "printf 'python_version = 3.12\n' >> /etc/${OE_CONFIG}.conf"

    if [ $IS_ENTERPRISE = "True" ]; then
        sudo su root -c "printf 'addons_path=${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons\n' >> /etc/${OE_CONFIG}.conf"
    else
        sudo su root -c "printf 'addons_path=${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons\n' >> /etc/${OE_CONFIG}.conf"
    fi
    sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
    sudo chmod 640 /etc/${OE_CONFIG}.conf
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "Server config file creation failed" $?
    exit 1
}

echo -e "* Create startup file"
log_message "Creating startup file..."
{
    sudo su root -c "echo '#!/bin/sh' >> $OE_HOME_EXT/start.sh"
    sudo su root -c "echo 'sudo -u $OE_USER $OE_HOME_EXT/odoo-bin --config=/etc/${OE_CONFIG}.conf' >> $OE_HOME_EXT/start.sh"
    sudo chmod 755 $OE_HOME_EXT/start.sh
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "Startup file creation failed" $?
    exit 1
}

#--------------------------------------------------
# Adding ODOO as a deamon (initscript)
#--------------------------------------------------

echo -e "* Create init file"
log_message "Creating init file..."
{
    cat <<EOF > ~/$OE_CONFIG
#!/bin/sh
### BEGIN INIT INFO
# Provides: $OE_CONFIG
# Required-Start: \$remote_fs \$syslog
# Required-Stop: \$remote_fs \$syslog
# Should-Start: \$network
# Should-Stop: \$network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Enterprise Business Applications
# Description: ODOO Business Applications
### END INIT INFO
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
DAEMON=$OE_HOME_EXT/odoo-bin
NAME=$OE_CONFIG
DESC=$OE_CONFIG
# Specify the user name (Default: odoo).
USER=$OE_USER
# Specify an alternate config file (Default: /etc/openerp-server.conf).
CONFIGFILE="/etc/${OE_CONFIG}.conf"
# pidfile
PIDFILE=/var/run/\${NAME}.pid
# Additional options that are passed to the Daemon.
DAEMON_OPTS="-c \$CONFIGFILE"
[ -x \$DAEMON ] || exit 0
[ -f \$CONFIGFILE ] || exit 0
checkpid() {
[ -f \$PIDFILE ] || return 1
pid=\`cat \$PIDFILE\`
[ -d /proc/\$pid ] && return 0
return 1
}
case "\${1}" in
start)
echo -n "Starting \${DESC}: "
start-stop-daemon --start --quiet --pidfile \$PIDFILE \
--chuid \$USER --background --make-pidfile \
--exec \$DAEMON -- \$DAEMON_OPTS
echo "\${NAME}."
;;
stop)
echo -n "Stopping \${DESC}: "
start-stop-daemon --stop --quiet --pidfile \$PIDFILE \
--oknodo
echo "\${NAME}."
;;
restart|force-reload)
echo -n "Restarting \${DESC}: "
start-stop-daemon --stop --quiet --pidfile \$PIDFILE \
--oknodo
sleep 1
start-stop-daemon --start --quiet --pidfile \$PIDFILE \
--chuid \$USER --background --make-pidfile \
--exec \$DAEMON -- \$DAEMON_OPTS
echo "\${NAME}."
;;
*)
N=/etc/init.d/\$NAME
echo "Usage: \$NAME {start|stop|restart|force-reload}" >&2
exit 1
;;
esac
exit 0
EOF

    echo -e "* Security Init File"
    sudo mv ~/$OE_CONFIG /etc/init.d/$OE_CONFIG
    sudo chmod 755 /etc/init.d/$OE_CONFIG
    sudo chown root: /etc/init.d/$OE_CONFIG
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "Init file creation failed" $?
    exit 1
}

echo -e "* Start ODOO on Startup"
log_message "Starting ODOO on Startup..."
{
    sudo update-rc.d $OE_CONFIG defaults
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "Starting ODOO on Startup failed" $?
    exit 1
}

#--------------------------------------------------
# Install Nginx if needed
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ]; then
    echo -e "\n---- Installing and setting up Nginx ----"
    log_message "Installing and setting up Nginx..."
    {
        sudo apt install nginx -y
        cat <<EOF > ~/odoo
server {
  listen 80;

  # set proper server name after domain set
  server_name $WEBSITE_NAME;

  # Add Headers for odoo proxy mode
  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-XSS-Protection "1; mode=block";
  proxy_set_header X-Client-IP \$remote_addr;
  proxy_set_header HTTP_X_FORWARDED_HOST \$remote_addr;

  #   odoo    log files
  access_log  /var/log/nginx/$OE_USER-access.log;
  error_log       /var/log/nginx/$OE_USER-error.log;

  #   increase    proxy   buffer  size
  proxy_buffers   16  64k;
  proxy_buffer_size   128k;

  proxy_read_timeout 900s;
  proxy_connect_timeout 900s;
  proxy_send_timeout 900s;

  #   force   timeouts    if  the backend dies
  proxy_next_upstream error   timeout invalid_header  http_500    http_502
  http_503;

  types {
    text/less less;
    text/scss scss;
  }

  #   enable  data    compression
  gzip    on;
  gzip_min_length 1100;
  gzip_buffers    4   32k;
  gzip_types  text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
  gzip_vary   on;
  client_header_buffer_size 4k;
  large_client_header_buffers 4 64k;
  client_max_body_size 0;

  location / {
    proxy_pass    http://127.0.0.1:$OE_PORT;
    # by default, do not forward anything
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://127.0.0.1:$LONGPOLLING_PORT;
  }

  location ~* .(js|css|png|jpg|jpeg|gif|ico)$ {
    expires 2d;
    proxy_pass http://127.0.0.1:$OE_PORT;
    add_header Cache-Control "public, no-transform";
  }

  # cache some static data in memory for 60mins.
  location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404      1m;
    proxy_buffering    on;
    expires 864000;
    proxy_pass    http://127.0.0.1:$OE_PORT;
  }
}
EOF

        sudo mv ~/odoo /etc/nginx/sites-available/$WEBSITE_NAME
        sudo ln -s /etc/nginx/sites-available/$WEBSITE_NAME /etc/nginx/sites-enabled/$WEBSITE_NAME
        sudo rm /etc/nginx/sites-enabled/default
        sudo service nginx reload
        sudo su root -c "printf 'proxy_mode = True\n' >> /etc/${OE_CONFIG}.conf"
        echo "Done! The Nginx server is up and running. Configuration can be found at /etc/nginx/sites-available/$WEBSITE_NAME"
    } >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
        handle_error "Nginx installation and setup failed" $?
        exit 1
    }
else
    echo "Nginx isn't installed due to choice of the user!"
fi

#--------------------------------------------------
# Enable ssl with certbot
#--------------------------------------------------

if [ $INSTALL_NGINX = "True" ] && [ $ENABLE_SSL = "True" ] && [ $ADMIN_EMAIL != "odoo@example.com" ]  && [ $WEBSITE_NAME != "_" ];then
    log_message "Enabling SSL with certbot..."
    {
        sudo apt-get update -y
        sudo apt install snapd -y
        sudo snap install core; snap refresh core
        sudo snap install --classic certbot
        sudo apt-get install python3-certbot-nginx -y
        sudo certbot --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL --redirect
        sudo service nginx reload
        echo "SSL/HTTPS is enabled!"
    } >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
        handle_error "SSL/HTTPS enabling failed" $?
        exit 1
    }
else
    echo "SSL/HTTPS isn't enabled due to choice of the user or because of a misconfiguration!"
    if $ADMIN_EMAIL = "odoo@example.com";then 
        echo "Certbot does not support registering odoo@example.com. You should use real e-mail address."
    fi
    if $WEBSITE_NAME = "_";then
        echo "Website name is set as _. Cannot obtain SSL Certificate for _. You should use real website address."
    fi
fi

echo -e "* Starting Odoo Service"
log_message "Starting Odoo Service..."
{
    sudo su root -c "/etc/init.d/$OE_CONFIG start"
} >> $INSTALL_LOG_FILE 2>> $ERROR_LOG_FILE || {
    handle_error "Starting Odoo Service failed" $?
    exit 1
}

log_message "Installation completed!"
echo "-----------------------------------------------------------"
echo "Done! The Odoo server is up and running. Specifications:"
echo "Port: $OE_PORT"
echo "User service: $OE_USER"
echo "Configuraton file location: /etc/${OE_CONFIG}.conf"
echo "Logfile location: /var/log/$OE_USER"
echo "User PostgreSQL: $OE_USER"
echo "Code location: $OE_USER"
echo "Addons folder: $OE_USER/$OE_CONFIG/addons/"
echo "Password superadmin (database): $OE_SUPERADMIN"
echo "Start Odoo service: sudo service $OE_CONFIG start"
echo "Stop Odoo service: sudo service $OE_CONFIG stop"
echo "Restart Odoo service: sudo service $OE_CONFIG restart"
if [ $INSTALL_NGINX = "True" ]; then
    echo "Nginx configuration file: /etc/nginx/sites-available/$WEBSITE_NAME"
fi
echo "-----------------------------------------------------------"
echo "Installation logs are available at:"
echo "Main log: $INSTALL_LOG_FILE"
echo "Error log: $ERROR_LOG_FILE"
echo "-----------------------------------------------------------"