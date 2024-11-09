#!/bin/bash
################################################################################
# Script for installing Odoo on Ubuntu
# Author: Based on script by Yenthe Van Ginneken, modified to install Odoo without instances
#-------------------------------------------------------------------------------
# This script will install Odoo on your Ubuntu server.
# It will prompt for the Odoo version to install.
#-------------------------------------------------------------------------------
# To use this script:
# 1. Save it as odoo-install.sh
#    sudo nano odoo-install.sh
# 2. Make the script executable:
#    sudo chmod +x odoo-install.sh
# 3. Run the script:
#    sudo ./odoo-install.sh
################################################################################

# Base variables
INSTALL_WKHTMLTOPDF="True"
INSTALL_POSTGRESQL_FOURTEEN="True"

# Prompt for Odoo version
read -p "Enter the Odoo version to install (17 or 18): " OE_VERSION_INPUT
if [ "$OE_VERSION_INPUT" == "17" ]; then
    OE_VERSION="17.0"
elif [ "$OE_VERSION_INPUT" == "18" ]; then
    OE_VERSION="18.0"
else
    echo "Invalid Odoo version. Please enter 17 or 18."
    exit 1
fi

# Set OE_HOME and OE_HOME_EXT based on version
OE_USER="odoo"
OE_BASE_DIR="/odoo"
OE_VERSION_SHORT="$OE_VERSION_INPUT"
OE_HOME="$OE_BASE_DIR/odoo$OE_VERSION_SHORT"
OE_HOME_EXT="$OE_HOME/${OE_USER}-server"

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
    sudo apt-get install postgresql-14 -y
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

echo "-----------------------------------------------------------"
echo "Done! Odoo version $OE_VERSION_SHORT is installed."
echo "Code location: $OE_HOME_EXT"
echo "Custom addons folder: $CUSTOM_ADDONS"
echo "-----------------------------------------------------------"
