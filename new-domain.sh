#!/bin/bash
################################################################################
# Script to add a new domain to an existing Nginx configuration for an Odoo instance
#-------------------------------------------------------------------------------
# Prompts the user for a new domain and the existing Nginx config file (name only).
# Generates SSL certificates first, then appends the new domain configuration.
################################################################################

# Function to detect upstream names from an existing Nginx config file
detect_upstreams() {
    local config_file=$1
    odoo_upstream=$(grep -oP 'upstream\s+\K(odoo_[a-zA-Z0-9_]+)' "$config_file" | head -n 1)
    odoochat_upstream=$(grep -oP 'upstream\s+\K(odoochat_[a-zA-Z0-9_]+)' "$config_file" | head -n 1)
}

# Function to add a new domain to the Nginx config file
add_domain_to_nginx_config() {
    local domain=$1
    local config_file=$2
    local server_count=$3
    local odoo_upstream=$4
    local odoochat_upstream=$5

    # Append the new domain configuration to the existing config file
    sudo bash -c "cat >> ${config_file}" <<EOF

# WWW -> NON WWW Server ${server_count}
# http -> https
server {
  listen 80;
  server_name ${domain};
  rewrite ^(.*) https://\$host\$1 permanent;
}

server {
  listen 443 ssl;
  server_name ${domain};
  proxy_read_timeout 720s;
  proxy_connect_timeout 720s;
  proxy_send_timeout 720s;

  # SSL parameters
  ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
  ssl_session_timeout 30m;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
  ssl_prefer_server_ciphers off;

  # log
  access_log /var/log/nginx/${domain}.access.log;
  error_log /var/log/nginx/${domain}.error.log;

  # Redirect websocket requests to odoo gevent port
  location /websocket {
    proxy_pass http://${odoochat_upstream};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  # Redirect requests to odoo backend server
  location / {
    # Add Headers for odoo proxy mode
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
    proxy_pass http://${odoo_upstream};

    # Enable HSTS
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    # requires nginx 1.19.8
    #proxy_cookie_flags session_id samesite=lax secure;
  }

  # common gzip
  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
  gzip on;
}
EOF

    echo "New domain ${domain} has been added to ${config_file}."
}

# Prompt for the domain to add
read -p "Enter the new domain to add (e.g., example.com): " new_domain

# Validate domain name format
if [[ ! "$new_domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "Invalid domain name. Please use only letters, numbers, dots, and hyphens."
    exit 1
fi

# Prompt for the Nginx configuration file name (assumed to be in /etc/nginx/sites-available/)
read -p "Enter the name of the existing Nginx config file for the instance (e.g., test.example.com): " nginx_config_file_name

# Build the full path to the Nginx configuration file
nginx_config_file="/etc/nginx/sites-available/${nginx_config_file_name}"

# Check if the file exists
if [ ! -f "$nginx_config_file" ]; then
    echo "The specified Nginx configuration file does not exist."
    exit 1
fi

# Detect the upstream names from the existing Nginx config
detect_upstreams "$nginx_config_file"

if [ -z "$odoo_upstream" ] || [ -z "$odoochat_upstream" ]; then
    echo "Could not detect the upstream names in the config file. Please check the config."
    exit 1
fi

# First generate SSL certificates for the new domain with Certbot
echo "Generating SSL certificate for ${new_domain} with Certbot..."
sudo certbot certonly --nginx -d "$new_domain" --non-interactive --agree-tos --register-unsafely-without-email

# Check if Certbot was successful
if [ $? -ne 0 ]; then
    echo "Certbot failed to generate SSL certificates for ${new_domain}. Please check the domain and try again."
    exit 1
fi

# Count how many servers are already defined to set the correct server count
existing_server_count=$(grep -c "server_name" "$nginx_config_file")
new_server_count=$((existing_server_count + 1))

# Add the new domain to the Nginx config file
add_domain_to_nginx_config "$new_domain" "$nginx_config_file" "$new_server_count" "$odoo_upstream" "$odoochat_upstream"

# Test the Nginx configuration for syntax errors
sudo nginx -t
if [ $? -ne 0 ]; then
    echo "Nginx configuration test failed. Please check the configuration."
    exit 1
fi

# Reload Nginx to apply the changes
echo "Reloading Nginx..."
sudo systemctl reload nginx

echo "SSL certificate generated and Nginx configuration updated successfully!"
