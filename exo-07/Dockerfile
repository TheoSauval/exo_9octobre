FROM mysql:8.4
ENV MYSQL_ROOT_PASSWORD=rootpass
# Les scripts .sql de ce dossier sont exécutés au premier démarrage du conteneur
COPY init.sql /docker-entrypoint-initdb.d/01-init.sql
EXPOSE 3306
