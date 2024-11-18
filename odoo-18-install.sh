#!/bin/bash
################################################################################
# Script for installing Odoo 18 on Ubuntu
# Author: [Your Name]
#-------------------------------------------------------------------------------
# This script will install Odoo 18 on your Ubuntu server.
#-------------------------------------------------------------------------------
# To use this script:
# 1. Save it as odoo18-install.sh
#    sudo nano odoo18-install.sh
# 2. Make the script executable:
#    sudo chmod +x odoo18-install.sh
# 3. Run the script:
#    sudo ./odoo18-install.sh
################################################################################

# Base variables
INSTALL_WKHTMLTOPDF="True"
INSTALL_POSTGRESQL_FIFTEEN="True"

# Odoo version
OE_VERSION="18.0"
OE_VERSION_SHORT="18"

# Set OE_HOME and OE_HOME_EXT based on version
OE_USER="odoo"
OE_BASE_DIR="/odoo"
OE_HOME="$OE_BASE_DIR/odoo$OE_VERSION_SHORT"
OE_HOME_EXT="$OE_HOME/${OE_USER}-server"

#--------------------------------------------------
# Update Server and Install Dependencies
#--------------------------------------------------
echo -e "\n---- Update Server and Install Dependencies ----"
sudo apt-get update
sudo apt-get upgrade -y

# Install necessary packages
sudo apt-get install build-essential wget git -y
sudo apt-get install libxml2-dev libxslt1-dev zlib1g-dev -y
sudo apt-get install libsasl2-dev libldap2-dev libssl-dev -y
sudo apt-get install libpq-dev -y
sudo apt-get install libjpeg-dev libfreetype6-dev -y
sudo apt-get install liblcms2-dev libwebp-dev tcl8.6-dev tk8.6-dev -y
sudo apt-get install xz-utils libffi-dev libreadline6-dev libbz2-dev -y

# Install Python 3.11 and development headers
echo -e "\n---- Installing Python 3.11 ----"
sudo apt-get install software-properties-common -y
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt-get update
sudo apt-get install python3.11 python3.11-venv python3.11-dev -y

# Use Python 3.11
PYTHON_BIN=$(which python3.11)

# Verify Python installation
if [ -z "$PYTHON_BIN" ]; then
    echo "Python 3.11 is not installed. Exiting."
    exit 1
fi

echo "Using Python at $PYTHON_BIN"

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL Server ----"
if [ $INSTALL_POSTGRESQL_FIFTEEN = "True" ]; then
    echo -e "\n---- Installing PostgreSQL V15 ----"
    sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    sudo apt-get update
    sudo apt-get install postgresql-15 -y
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
    sudo adduser --system --quiet --shell=/bin/bash --home=$OE_BASE_DIR --gecos 'ODOO' --group $OE_USER
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

echo -e "\n---- Creating custom addons directory ----"
CUSTOM_ADDONS="$OE_HOME/custom/addons"
sudo mkdir -p $CUSTOM_ADDONS
sudo chown -R $OE_USER:$OE_USER $OE_HOME

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

# Install dependencies that support Python 3.11
sudo -u $OE_USER $OE_HOME/venv/bin/pip install psycopg2-binary
sudo -u $OE_USER $OE_HOME/venv/bin/pip install -r $OE_HOME_EXT/requirements.txt

if [ $? -ne 0 ]; then
    echo "Failed to install Python requirements. Exiting."
    exit 1
fi

echo -e "\n---- Installing Node.js 16 and rtlcss for RTL support ----"
curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g rtlcss

#--------------------------------------------------
# Install Wkhtmltopdf (Patched Version)
#--------------------------------------------------
if [ $INSTALL_WKHTMLTOPDF = "True" ]; then
  echo -e "\n---- Installing patched wkhtmltopdf 0.12.5 ----"
  if [ "`getconf LONG_BIT`" == "64" ]; then
    # 64-bit system
    WKHTMLTOX_X64="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.focal_amd64.deb"
    sudo wget $WKHTMLTOX_X64
    sudo dpkg -i wkhtmltox_0.12.5-1.focal_amd64.deb
    sudo apt-get install -f -y
    sudo ln -s /usr/local/bin/wkhtmltopdf /usr/bin
    sudo ln -s /usr/local/bin/wkhtmltoimage /usr/bin
  else
    # 32-bit system
    WKHTMLTOX_X86="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.focal_i386.deb"
    sudo wget $WKHTMLTOX_X86
    sudo dpkg -i wkhtmltox_0.12.5-1.focal_i386.deb
    sudo apt-get install -f -y
    sudo ln -s /usr/local/bin/wkhtmltopdf /usr/bin
    sudo ln -s /usr/local/bin/wkhtmltoimage /usr/bin
  fi
else
  echo "Wkhtmltopdf isn't installed due to the choice of the user!"
fi

echo "-----------------------------------------------------------"
echo "Done! Odoo version $OE_VERSION_SHORT is installed."
echo "Code location: $OE_HOME_EXT"
echo "Custom addons folder: $CUSTOM_ADDONS"
echo "-----------------------------------------------------------"
