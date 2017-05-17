#!/usr/bin/env bash
set -e

echo "--> Grabbing IPs"
PRIVATE_IP=$(curl --silent http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl --silent http://169.254.169.254/latest/meta-data/public-ipv4)

echo "--> Adding helper for IP retrieval"
sudo tee /etc/profile.d/ips.sh > /dev/null <<EOF
function private-ip {
  echo "$PRIVATE_IP"
}

function public-ip {
  echo "$PUBLIC_IP"
}
EOF

echo "--> Updating apt-cache"
sudo apt-get update &>/dev/null

echo "--> Installing common dependencies"
sudo apt-get -yqq install \
  build-essential \
  curl \
  emacs \
  git \
  jq \
  unzip \
  vim \
  wget \
  &>/dev/null

echo "--> Setting AWS envvars"
sudo tee /etc/profile.d/aws.sh > /dev/null <<"EOF"
export AWS_ACCESS_KEY_ID="${aws_access_key}"
export AWS_SECRET_ACCESS_KEY="${aws_secret_key}"
export AWS_REGION="${aws_region}"
EOF
source /etc/profile.d/aws.sh

echo "--> Disabling checkpoint"
sudo tee /etc/profile.d/checkpoint.sh > /dev/null <<"EOF"
export CHECKPOINT_DISABLE=1
EOF
source /etc/profile.d/checkpoint.sh

echo "--> Setting hostname..."
echo "127.0.0.1  ${hostname}" | sudo tee -a /etc/hosts
echo "${hostname}" | sudo tee /etc/hostname
sudo hostname -F /etc/hostname

echo "--> Creating user"
sudo useradd "${username}" \
  --shell /bin/bash \
  --create-home
echo "${username}:${password}" | sudo chpasswd
sudo tee "/etc/sudoers.d/${username}" > /dev/null <<"EOF"
%${username} ALL=NOPASSWD:ALL
EOF
sudo chmod 0440 "/etc/sudoers.d/${username}"
sudo usermod -a -G sudo "${username}"
sudo su "${username}" \
  -c "ssh-keygen -q -t rsa -N '' -b 4096 -f ~/.ssh/id_rsa -C demo@hashicorp.com"
sudo sed -i "/^PasswordAuthentication/c\PasswordAuthentication yes" /etc/ssh/sshd_config
sudo service ssh restart
sudo su "${username}" \
  -c 'git config --global color.ui true'
sudo su "${username}" \
  -c 'git config --global user.email "demo@hashicorp.com"'
sudo su ${username} \
  -c 'git config --global user.name "HashiCorp Demo"'
sudo su ${username} \
  -c 'git config --global credential.helper "cache --timeout=3600"'
sudo su ${username} \
  -c 'mkdir -p ~/.cache; touch ~/.cache/motd.legal-displayed'

echo "--> Configuring MOTD"
sudo rm -rf /etc/update-motd.d/*
sudo tee /etc/update-motd.d/00-hashicorp > /dev/null <<"EOF"
#!/bin/sh

echo "Welcome to the HashiCorp demo! Have a great day!"
EOF
sudo chmod +x /etc/update-motd.d/00-hashicorp
sudo run-parts /etc/update-motd.d/ &>/dev/null

echo "--> Ignoring LastLog"
sudo sed -i'' 's/PrintLastLog\ yes/PrintLastLog\ no/' /etc/ssh/sshd_config
sudo service ssh restart &>/dev/null

echo "--> Setting bash prompt"
sudo tee -a "/home/${username}/.bashrc" > /dev/null <<"EOF"
export PS1="\u@hashicorp > "
EOF

echo "--> Fetching Vault..."
pushd /tmp &>/dev/null
curl \
  --silent \
  --location \
  --output vault.zip \
  "${vault_url}"
unzip -qq vault.zip
sudo mv vault /usr/local/bin/vault
sudo chmod +x /usr/local/bin/vault
rm -rf vault.zip
popd &>/dev/null

echo "--> Writing configuration"
sudo mkdir -p /mnt/vault
sudo mkdir -p /etc/vault.d
sudo tee /etc/vault.d/config.hcl > /dev/null <<EOF
ui           = true
cluster_name = "vault-demo"
EOF

echo "--> Writing profile"
sudo tee /etc/profile.d/vault.sh > /dev/null <<"EOF"
alias vualt="vault"
export VAULT_ADDR="http://127.0.0.1:8200"
EOF
source /etc/profile.d/vault.sh

echo "--> Generating upstart configuration"
sudo tee /etc/init/vault.conf > /dev/null <<"EOF"
description "vault"

start on runlevel [2345]
stop on runlevel [06]

respawn
post-stop exec sleep 5

env VAULT_DEV_ROOT_TOKEN_ID="root"

exec /usr/local/bin/vault server \
  -dev \
  -config="/etc/vault.d/config.hcl"
EOF

echo "--> Creating helpers"
sudo tee "/home/${username}/setup-pg-connection.sh" > /dev/null <<"EOF"
vault write database/config/postgresql \
  plugin_name="postgresql-database-plugin" \
  connection_url="postgresql://postgres@localhost:5432/myapp" \
  allowed_roles="readonly" \
  &>/dev/null
EOF
sudo chmod +x "/home/${username}/setup-pg-connection.sh"
sudo chown "${username}:${username}" "/home/${username}/setup-pg-connection.sh"

sudo tee "/home/${username}/setup-pg-role.sh" > /dev/null <<"EOF"
vault write database/roles/readonly \
  db_name="postgresql" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"
EOF
sudo chmod +x "/home/${username}/setup-pg-role.sh"
sudo chown "${username}:${username}" "/home/${username}/setup-pg-role.sh"

sudo tee "/home/${username}/setup-aws-connection.sh" > /dev/null <<"EOF"
vault write aws/config/root \
  access_key="$AWS_ACCESS_KEY_ID" \
  secret_key="$AWS_SECRET_ACCESS_KEY" \
  region="$AWS_REGION"
EOF
sudo chmod +x "/home/${username}/setup-aws-connection.sh"
sudo chown "${username}:${username}" "/home/${username}/setup-aws-connection.sh"

sudo tee "/home/${username}/iam-policy.json" > /dev/null <<"EOF"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iam:*",
      "Resource": "*"
    }
  ]
}
EOF
sudo chown "${username}:${username}" "/home/${username}/iam-policy.json"

sudo tee "/home/${username}/setup-pki.sh" > /dev/null <<"EOF"
vault mount pki &>/dev/null
vault mount-tune -max-lease-ttl=87600h pki &>/dev/null
vault write pki/root/generate/internal \
  common_name=example.com \
  ttl=87600h \
  &>/dev/null
vault write pki/config/urls \
  issuing_certificates="http://127.0.0.1:8200/v1/pki/ca" \
  crl_distribution_points="http://127.0.0.1:8200/v1/pki/crl" \
  &>/dev/null
vault write pki/roles/my-website \
  allowed_domains="example.com" \
  allow_subdomains="true" \
  max_ttl="72h" \
  &>/dev/null
EOF
sudo chmod +x "/home/${username}/setup-pki.sh"
sudo chown "${username}:${username}" "/home/${username}/setup-pki.sh"

sudo tee "/home/${username}/otp-url.txt" > /dev/null <<"EOF"
otpauth://totp/Vault:seth@sethvargo.com?secret=Y64VEVMBTSXCYIWRSHRNDZW62MPGVU2G&issuer=Vault
EOF
sudo chown "${username}:${username}" "/home/${username}/otp-url.txt"

echo "--> Installing Ruby"
sudo apt-add-repository -y ppa:brightbox/ruby-ng &>/dev/null
sudo apt-get -yqq update &>/dev/null
sudo apt-get -yqq install ruby2.4 &>/dev/null
sudo gem update --silent --system &>/dev/null

echo "--> Instaling postgresql"
curl -s https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo apt-get -yqq update &>/dev/null
sudo apt-get -yqq install postgresql postgresql-contrib &> /dev/null
sudo tee /etc/postgresql/*/main/pg_hba.conf > /dev/null <<"EOF"
local   all             postgres                                trust
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
EOF
sudo service postgresql restart &>/dev/null

echo "--> Creating database myapp"
psql -U postgres -c 'CREATE DATABASE myapp;' &>/dev/null

echo "--> Setting psql prompt"
sudo tee "/home/${username}/.psqlrc" > /dev/null <<"EOF"
\set QUIET 1
\set COMP_KEYWORD_CASE upper
\set PROMPT1 '%n > '

\echo 'Welcome to PostgreSQL!'
\echo 'Type \\q to exit.\n'
EOF

echo "--> Ensuring .psqlrc is owned by ${username}"
sudo chown "${username}:${username}" "/home/${username}/.psqlrc"

function install_tool {
  local tool="$1"
  local version="$2"

  echo "--> Installing $${tool}"
  pushd /tmp &>/dev/null
  curl \
    --silent \
    --location \
    --output "$${tool}.zip" \
    "https://releases.hashicorp.com/$${tool}/$${version}/$${tool}_$${version}_linux_amd64.zip"
  unzip -qq "$${tool}.zip"
  sudo mv "$${tool}" "/usr/local/bin/$${tool}"
  sudo chmod +x "/usr/local/bin/$${tool}"
  rm -rf "$${tool}".zip
  popd &>/dev/null
}

install_tool "consul-template" "${consul_template_version}"
install_tool "envconsul" "${envconsul_version}"

echo "--> Install nginx"
sudo apt-get -yqq install nginx &> /dev/null

echo "--> Writing nginx configuration"
sudo tee "/etc/nginx/sites-enabled/default" > /dev/null <<"EOF"
server {
  listen 80;
  server_name ${hostname};

  add_header X-Frame-Options DENY;
  add_header X-Content-Type-Options nosniff;

  location / {
    proxy_pass http://127.0.0.1:8200/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
EOF

echo "--> Restarting nginx..."
sudo service nginx restart

echo "--> Rebooting"
sudo reboot
