#!/bin/bash

# Script de instalación de Odoo 18 en Ubuntu 24.04 LTS

# Salir inmediatamente si un comando falla
set -e

# Solicitar la contraseña para el usuario de PostgreSQL
read -s -p "Ingresa la contraseña para el usuario de PostgreSQL 'odoo18': " DB_PASSWORD
echo

echo "Actualizando el servidor..."
sudo apt-get update
sudo apt-get upgrade -y

echo "Instalando y configurando medidas de seguridad..."
sudo apt-get install -y openssh-server fail2ban
sudo systemctl start fail2ban
sudo systemctl enable fail2ban

echo "Instalando paquetes y librerías requeridas..."
sudo apt-get install -y python3-pip python3-dev libxml2-dev libxslt1-dev zlib1g-dev \
libsasl2-dev libldap2-dev build-essential libssl-dev libffi-dev libjpeg-dev libpq-dev \
liblcms2-dev libblas-dev libatlas-base-dev npm node-less git python3-venv

echo "Instalando Node.js y NPM..."
sudo apt-get install -y nodejs npm

if [ ! -f /usr/bin/node ]; then
    echo "Creando enlace simbólico para node..."
    sudo ln -s /usr/bin/nodejs /usr/bin/node
fi

echo "Instalando less y less-plugin-clean-css..."
sudo npm install -g less less-plugin-clean-css

echo "Instalando PostgreSQL..."
sudo apt-get install -y postgresql

echo "Creando usuario de PostgreSQL para Odoo..."
sudo -u postgres psql -c "CREATE USER odoo18 WITH CREATEDB SUPERUSER PASSWORD '$DB_PASSWORD';"

echo "Creando usuario de sistema para Odoo..."
sudo adduser --system --home=/odoo --group odoo18

echo "Clonando Odoo 18 desde GitHub..."
sudo -u odoo18 -H git clone --depth 1 --branch master --single-branch https://www.github.com/odoo/odoo /odoo/

echo "Creando entorno virtual de Python..."
sudo -u odoo18 -H python3 -m venv /odoo/venv

echo "Instalando paquetes Python requeridos..."
sudo -u odoo18 -H /odoo/venv/bin/pip install wheel
sudo -u odoo18 -H /odoo/venv/bin/pip install -r /odoo/requirements.txt

echo "Instalando wkhtmltopdf..."
sudo apt-get install -y xfonts-75dpi
sudo wget https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.focal_i386.deb
sudo dpkg -i wkhtmltox_0.12.5-1.focal_i386.deb
sudo apt-get install -f -y
sudo ln -s /usr/local/bin/wkhtmltopdf /usr/bin
sudo ln -s /usr/local/bin/wkhtmltoimage /usr/bin
