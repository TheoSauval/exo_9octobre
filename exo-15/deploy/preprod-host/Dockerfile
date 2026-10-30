# Hôte "distant" de préprod pour le TP09 : moteur Docker (docker-in-docker) + serveur SSH.
# L'utilisateur deploy (groupe docker, clé SSH uniquement) est celui qu'utilise "docker context".
FROM docker:27.3.1-dind
# --upgrade : le client ssh de l'image de base est plus ancien que le serveur à installer (conflit apk)
RUN apk add --no-cache --upgrade openssh-server openssh-client-common openssh-client-default \
 && (addgroup -S docker 2>/dev/null || true) \
 && adduser -D -u 1000 -s /bin/sh deploy \
 && addgroup deploy docker \
 && sed -i 's/^deploy:!/deploy:*/' /etc/shadow \
 && install -d -o deploy -g deploy -m 750 /srv/shop
COPY sshd_config /etc/ssh/sshd_config
COPY --chmod=755 entrypoint.sh /usr/local/bin/preprod-entrypoint.sh
EXPOSE 22 80
ENTRYPOINT ["/usr/local/bin/preprod-entrypoint.sh"]
# le registre de la CI est en HTTP (TP) : déclaré "insecure" côté moteur du serveur
CMD ["--insecure-registry=host.docker.internal:5050"]
