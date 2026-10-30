#!/bin/sh
set -e
# clé publique de la CI fournie au démarrage : installée avec les droits exigés par sshd (StrictModes)
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
install -m 600 -o deploy -g deploy /run/authorized_keys /home/deploy/.ssh/authorized_keys
ssh-keygen -A >/dev/null
/usr/sbin/sshd -E /var/log/sshd.log
exec dockerd-entrypoint.sh "$@"
