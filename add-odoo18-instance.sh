#!/bin/bash
################################################################################
# Script para agregar una instancia de Odoo 18 a una configuración de servidor existente
#-------------------------------------------------------------------------------
# Este script verifica qué instancias ya están instaladas, identifica puertos disponibles
# y agrega una nueva instancia de Odoo 18 con la configuración elegida.
#-------------------------------------------------------------------------------
# Uso:
# 1. Guárdalo como add-odoo18-instance.sh
#    sudo nano add-odoo18-instance.sh
# 2. Haz el script ejecutable:
#    sudo chmod +x add-odoo18-instance.sh
# 3. Ejecuta el script:
#    sudo ./add-odoo18-instance.sh
################################################################################

# Salir inmediatamente si un comando falla
set -e

# Función para generar una contraseña aleatoria
generate_random_password() {
    openssl rand -base64 16
}

# Asegurarse de que los paquetes necesarios estén instalados
install_package() {
    local PACKAGE=$1
    if ! dpkg -s "$PACKAGE" &> /dev/null; then
        echo "$PACKAGE no está instalado. Instalando $PACKAGE..."
        sudo apt update
        sudo apt install "$PACKAGE" -y
    fi
}

# Asegurar que los paquetes necesarios estén instalados
install_package "lsof"
install_package "nginx"
install_package "snapd"
install_package "openssl"  # Asegurarse de que openssl esté instalado
install_package "git"      # Asegurarse de que git esté instalado

# Instalar Certbot si no está instalado
if ! command -v certbot &> /dev/null; then
    echo "Instalando Certbot..."
    sudo snap install core
    sudo snap refresh core
    sudo snap install --classic certbot
    sudo ln -sf /snap/bin/certbot /usr/bin/certbot
fi

# Variables base
OE_USER="odoo18"
INSTALL_WKHTMLTOPDF="True"
GENERATE_RANDOM_PASSWORD="True"
BASE_ODOO_PORT=8069
BASE_GEVENT_PORT=9069  # Puerto base para gevent (websocket)

# Obtener la dirección IP del servidor
SERVER_IP=$(hostname -I | awk '{print $1}')

# Arrays para almacenar instancias y puertos existentes
declare -a EXISTING_INSTANCE_NAMES
declare -a EXISTING_OE_PORTS
declare -a EXISTING_GEVENT_PORTS

# Versión de Odoo
OE_VERSION="18.0"
OE_VERSION_SHORT="18"
PYTHON_VERSION="3.11"

# Asegurarse de que la versión requerida de Python esté instalada
if ! command -v python${PYTHON_VERSION} &> /dev/null; then
    echo "Python ${PYTHON_VERSION} no está instalado. Instalando Python ${PYTHON_VERSION}..."
    sudo apt update
    sudo apt install software-properties-common -y
    sudo add-apt-repository ppa:deadsnakes/ppa -y
    sudo apt update
    sudo apt install python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev -y
fi

# Ajustar rutas basadas en tu instalación
OE_BASE_DIR="/odoo"
OE_HOME="$OE_BASE_DIR"
OE_HOME_EXT="$OE_HOME"

# Directorios de addons Enterprise (opcional)
ENTERPRISE_DIR="${OE_HOME}/enterprise"
ENTERPRISE_ADDONS="${ENTERPRISE_DIR}/addons"

# Recolectar instancias existentes
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
    echo "No se encontraron instancias existentes de Odoo."
fi

# Función para encontrar un puerto disponible
find_available_port() {
    local BASE_PORT=$1
    local -n EXISTING_PORTS=$2
    local PORT=$BASE_PORT
    while true; do
        # Verificar si el puerto está en uso o en la lista de puertos existentes
        if [[ " ${EXISTING_PORTS[@]} " =~ " $PORT " ]] || lsof -i TCP:$PORT >/dev/null 2>&1; then
            PORT=$((PORT + 1))
        else
            echo "$PORT"
            break
        fi
    done
}

# Solicitar el nombre de la instancia
read -p "Ingresa el nombre para la nueva instancia (por ejemplo, odoo1): " INSTANCE_NAME

# Validar el nombre de la instancia
if [[ ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Nombre de instancia inválido. Solo se permiten letras, números, guiones bajos y guiones."
    exit 1
fi

# Función para crear usuario de PostgreSQL con contraseña aleatoria
create_postgres_user() {
    local DB_USER=$1
    local DB_PASSWORD=$2

    # Guardar el directorio actual
    ORIGINAL_DIR=$(pwd)
    # Cambiar a un directorio accesible por el usuario postgres
    cd /tmp

    # Verificar si el usuario de PostgreSQL ya existe
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
        echo "El usuario de PostgreSQL '$DB_USER' ya existe. Saltando creación."
    else
        # Crear el usuario de la base de datos
        sudo -u postgres psql -c "CREATE USER $DB_USER WITH CREATEDB NOSUPERUSER NOCREATEROLE PASSWORD '$DB_PASSWORD';"
        echo "Usuario de PostgreSQL '$DB_USER' creado exitosamente."
    fi

    # Volver al directorio original
    cd "$ORIGINAL_DIR"
}

# Solicitar si tiene licencia Enterprise
read -p "¿Tienes una licencia Enterprise para la base de datos de esta instancia? Tendrás que ingresar tu código de licencia después de la instalación (sí/no): " ENTERPRISE_CHOICE
if [[ "$ENTERPRISE_CHOICE" =~ ^(sí|si|s)$ ]]; then
    HAS_ENTERPRISE_LICENSE="True"
else
    HAS_ENTERPRISE_LICENSE="False"
fi
echo "HAS_ENTERPRISE_LICENSE está configurado como '$HAS_ENTERPRISE_LICENSE'"

# Verificar si la instancia ya existe
if [[ " ${EXISTING_INSTANCE_NAMES[@]} " =~ " ${INSTANCE_NAME} " ]]; then
    echo "Ya existe una instancia con el nombre '$INSTANCE_NAME'. Por favor, elige un nombre diferente."
    exit 1
fi

# Configurar OE_CONFIG para la instancia
OE_CONFIG="${OE_USER}-server-${INSTANCE_NAME}"

# Encontrar puertos disponibles
OE_PORT=$(find_available_port $BASE_ODOO_PORT EXISTING_OE_PORTS)
GEVENT_PORT=$(find_available_port $BASE_GEVENT_PORT EXISTING_GEVENT_PORTS)

echo "Puertos asignados:"
echo "  Puerto XML-RPC: $OE_PORT"
echo "  Puerto Gevent (WebSocket): $GEVENT_PORT"

# Preguntar si desea habilitar SSL para esta instancia
read -p "¿Deseas habilitar SSL con Certbot para la instancia '$INSTANCE_NAME'? (sí/no): " SSL_CHOICE
if [[ "$SSL_CHOICE" =~ ^(sí|si|s)$ ]]; then
    ENABLE_SSL="True"
    # Solicitar nombre de dominio y correo electrónico de administrador
    read -p "Ingresa el nombre de dominio para la instancia (por ejemplo, odoo.miempresa.com): " WEBSITE_NAME
    read -p "Ingresa tu dirección de correo electrónico para el registro del certificado SSL: " ADMIN_EMAIL

    # Validar nombre de dominio
    if [[ ! "$WEBSITE_NAME" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo "Nombre de dominio inválido."
        exit 1
    fi

    # Validar correo electrónico
    if ! [[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "Dirección de correo electrónico inválida."
        exit 1
    fi
else
    ENABLE_SSL="False"
    # Sin SSL, usamos la IP del servidor
    WEBSITE_NAME=$SERVER_IP
fi

# Generar OE_SUPERADMIN
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    OE_SUPERADMIN=$(generate_random_password)
    echo "Contraseña aleatoria de superadministrador generada."
else
    read -s -p "Ingresa la contraseña de superadministrador para la base de datos: " OE_SUPERADMIN
    echo
fi

# Generar contraseña aleatoria para el usuario de PostgreSQL
DB_PASSWORD=$(generate_random_password)
echo "Contraseña aleatoria para PostgreSQL generada."

# Crear usuario de PostgreSQL
create_postgres_user "$INSTANCE_NAME" "$DB_PASSWORD"

echo -e "\n==== Configurando instancia de ODOO '$INSTANCE_NAME' ===="

# Crear directorio de addons personalizados para la instancia
INSTANCE_DIR="${OE_HOME}/${INSTANCE_NAME}"
sudo mkdir -p "${INSTANCE_DIR}/custom/addons"
sudo chown -R $OE_USER:$OE_USER "${INSTANCE_DIR}"

# Si tiene licencia Enterprise, configurar el directorio de addons Enterprise
if [ "$HAS_ENTERPRISE_LICENSE" = "True" ]; then
    echo "Configurando directorio de addons Enterprise..."
    # Crear el directorio Enterprise si no existe
    if [ ! -d "$ENTERPRISE_ADDONS" ]; then
        sudo mkdir -p "$ENTERPRISE_ADDONS"
        sudo chown -R $OE_USER:$OE_USER "$ENTERPRISE_DIR"
        echo "Directorio de addons Enterprise creado en $ENTERPRISE_ADDONS"
    else
        echo "El directorio de addons Enterprise ya existe en $ENTERPRISE_ADDONS"
    fi
    echo "Por favor, asegúrate de clonar el código Enterprise en $ENTERPRISE_ADDONS"
fi

# Usar el entorno virtual existente
INSTANCE_VENV="${OE_HOME}/venv"

# Determinar addons_path basado en la elección de licencia Enterprise
if [ "$HAS_ENTERPRISE_LICENSE" = "True" ]; then
    ADDONS_PATH="${OE_HOME_EXT}/addons,${INSTANCE_DIR}/custom/addons,${ENTERPRISE_ADDONS}"
else
    ADDONS_PATH="${OE_HOME_EXT}/addons,${INSTANCE_DIR}/custom/addons"
fi

echo -e "\n---- Creando archivo de configuración del servidor para la instancia '$INSTANCE_NAME' ----"
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

# Crear archivo de servicio systemd para la instancia
echo -e "\n---- Creando archivo de servicio systemd para la instancia '$INSTANCE_NAME' ----"
SERVICE_FILE="${OE_CONFIG}.service"
sudo bash -c "cat > /etc/systemd/system/${SERVICE_FILE}" <<EOF
[Unit]
Description=Odoo Open Source ERP and CRM - Instancia ${INSTANCE_NAME}
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

# Recargar el demonio systemd y iniciar el servicio
echo -e "\n---- Iniciando el servicio ODOO para la instancia '$INSTANCE_NAME' ----"
sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_FILE}
sudo systemctl start ${SERVICE_FILE}

# Verificar si el servicio se inició correctamente
sudo systemctl is-active --quiet ${SERVICE_FILE}
if [ $? -ne 0 ]; then
    echo "El servicio ${SERVICE_FILE} no pudo iniciarse. Por favor, revisa los logs."
    sudo journalctl -u ${SERVICE_FILE} --no-pager
    exit 1
fi

echo "El servicio Odoo para la instancia '$INSTANCE_NAME' se inició correctamente."

#--------------------------------------------------
# Configurar Nginx para esta instancia
#--------------------------------------------------
# (La configuración de Nginx permanece igual que en tu script original, así que puedes mantener esa sección sin cambios)

# [Continúa con la configuración de Nginx y Certbot según sea necesario]

echo "-----------------------------------------------------------"
echo "¡La instancia '$INSTANCE_NAME' se ha agregado exitosamente!"
echo "-----------------------------------------------------------"
echo "Puertos:"
echo "  Puerto XML-RPC: $OE_PORT"
echo "  Puerto Gevent (WebSocket): $GEVENT_PORT"
echo ""
echo "Información del servicio:"
echo "  Nombre del servicio: ${SERVICE_FILE}"
echo "  Archivo de configuración: /etc/${OE_CONFIG}.conf"
echo "  Archivo de log: /var/log/${OE_USER}/${OE_CONFIG}.log"
echo ""
echo "Carpeta de addons personalizados: ${INSTANCE_DIR}/custom/addons/"
if [ "$HAS_ENTERPRISE_LICENSE" = "True" ]; then
    echo "Carpeta de addons Enterprise: ${ENTERPRISE_ADDONS}"
fi
echo ""
echo "Información de la base de datos:"
echo "  Usuario de la base de datos: $INSTANCE_NAME"
echo "  Contraseña de la base de datos: $DB_PASSWORD"
echo ""
echo "Información de superadministrador:"
echo "  Contraseña de superadministrador: $OE_SUPERADMIN"
echo ""
echo "Administra el servicio de Odoo con los siguientes comandos:"
echo "  Iniciar:   sudo systemctl start ${SERVICE_FILE}"
echo "  Detener:   sudo systemctl stop ${SERVICE_FILE}"
echo "  Reiniciar: sudo systemctl restart ${SERVICE_FILE}"
echo ""
if [ "$ENABLE_SSL" = "True" ]; then
    echo "Archivo de configuración de Nginx: /etc/nginx/sites-available/${WEBSITE_NAME}"
    echo "URL de acceso: https://${WEBSITE_NAME}"
else
    echo "Archivo de configuración de Nginx: /etc/nginx/sites-available/${INSTANCE_NAME}"
    echo "URL de acceso: http://${SERVER_IP}:${OE_PORT}"
fi
echo "-----------------------------------------------------------"
