#!/bin/sh
# Installs the SayoSign signing server on a Linux box with nginx in front.
# Usage: sudo server/install.sh https://example.com/sign
set -e
PUBLIC_BASE="${1:?usage: install.sh https://host/sign}"
cd "$(dirname "$0")/.."
make
install -d /opt/sayosign-server/bin /var/lib/sayosign-server /var/www/sign/out
install -m 755 build/sayosign /opt/sayosign-server/bin/sayosign
install -m 755 server/sayosign_server.py /opt/sayosign-server/sayosign_server.py
if [ ! -f /etc/sayosign-server.env ]; then
  umask 077
  cat > /etc/sayosign-server.env <<ENV
SAYOSIGN_TOKEN=$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')
SAYOSIGN_PUBLIC=${PUBLIC_BASE%/}/out
SAYOSIGN_BIN=/opt/sayosign-server/bin/sayosign
SAYOSIGN_DATA=/var/lib/sayosign-server
SAYOSIGN_OUT=/var/www/sign/out
SAYOSIGN_LISTEN=127.0.0.1:8799
ENV
fi
install -m 644 server/sayosign-server.service /etc/systemd/system/sayosign-server.service
systemctl daemon-reload
systemctl enable --now sayosign-server
systemctl restart sayosign-server
. /etc/sayosign-server.env
echo "Add server/nginx.conf to your site, then open on the iPhone:"
echo "sayosign://server?url=${PUBLIC_BASE%/}&key=$SAYOSIGN_TOKEN"
