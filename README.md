# odoo-install-multi-instance
Odoo installation script for multiple instances in the same server, sharing base installation and enterprise addons if the databases have licenses or community if they have not license. Prompt options for instance name, domain and ssl certificates

Inspired by https://github.com/Yenthe666/InstallScript 

This scripts allows to install multiple instances in the same server
At running it will ask for how many instances should it create
It will prompt for each instance name, domain and choice of ssl or not

Tested and running on ubuntu 24.04 LTS

Use odoo-multi-install.sh to setup the server for the first time

Use add-odoo-instance.sh to add more instances, needs to be run with sudo

Use remove-odoo-instance.sh to list and remove a selected instance without affecting the others (won't remove the database, only the instance, if you want to remove the database, please do so before running the script)
