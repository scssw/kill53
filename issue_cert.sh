#!/usr/bin/env bash
set -euo pipefail

ACME="$HOME/.acme.sh/acme.sh"

if [ ! -x "$ACME" ]; then
  echo "Installing acme.sh..."
  curl https://get.acme.sh | sh
fi

read -r -p "Enter domain: " domain
if [ -z "${domain}" ]; then
  echo "Domain is required."
  exit 1
fi

if [ ! -f "$HOME/.acme.sh/account.conf" ]; then
  email_prefix=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
  email="${email_prefix}@gmail.com"
  "$ACME" --register-account -m "$email"
  echo "Registered account with email: $email"
else
  echo "Account already exists. Skipping account registration."
fi

"$ACME" --issue -d "$domain" --standalone

cert_dir="/root/cert/$domain"
mkdir -p "$cert_dir"

reload_cmd=""
if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' | grep -w "nginx" >/dev/null 2>&1; then
    reload_cmd="docker exec nginx nginx -s reload"
  fi
fi

if [ -z "$reload_cmd" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet nginx; then
      reload_cmd="systemctl reload nginx"
    fi
  fi
fi

if [ -n "$reload_cmd" ]; then
  "$ACME" --installcert -d "$domain" \
    --key-file "$cert_dir/privkey.pem" \
    --fullchain-file "$cert_dir/fullchain.pem" \
    --reloadcmd "$reload_cmd"
  echo "Installed certs to: $cert_dir (with reloadcmd: $reload_cmd)"
else
  "$ACME" --installcert -d "$domain" \
    --key-file "$cert_dir/privkey.pem" \
    --fullchain-file "$cert_dir/fullchain.pem"
  echo "Installed certs to: $cert_dir (no reloadcmd configured)"
  echo "Set reload command manually if needed."
fi

"$ACME" --renew-all --force >/dev/null 2>&1 || true

echo "Done."
