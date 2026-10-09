# Exercice Docker #7 - Base MySQL kennelDB pré-remplie

**Objectif :** construire une image MySQL qui démarre avec la base `kennelDB` déjà créée et remplie (clients, adresses, associations clients-adresses, chiens, chats), grâce à un script SQL d'initialisation.

Fichiers : dossier `exo-07/`.

---

## 1. Script d'initialisation - `init.sql`

```sql
-- Initialisation de la base kennelDB
CREATE DATABASE IF NOT EXISTS kennelDB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE kennelDB;

CREATE TABLE clients (
  id             INT AUTO_INCREMENT PRIMARY KEY,
  nom            VARCHAR(50)  NOT NULL,
  prenom         VARCHAR(50)  NOT NULL,
  date_naissance DATE         NOT NULL,
  pseudonyme     VARCHAR(50)  NOT NULL UNIQUE
);

CREATE TABLE adresses (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  numero      VARCHAR(10)  NOT NULL,
  rue         VARCHAR(100) NOT NULL,
  code_postal VARCHAR(5)   NOT NULL,
  commune     VARCHAR(100) NOT NULL
);

-- Association plusieurs-à-plusieurs clients <-> adresses
CREATE TABLE clients_adresses (
  client_id  INT NOT NULL,
  adresse_id INT NOT NULL,
  PRIMARY KEY (client_id, adresse_id),
  FOREIGN KEY (client_id)  REFERENCES clients(id)  ON DELETE CASCADE,
  FOREIGN KEY (adresse_id) REFERENCES adresses(id) ON DELETE CASCADE
);

CREATE TABLE chiens (
  id             INT AUTO_INCREMENT PRIMARY KEY,
  nom            VARCHAR(50) NOT NULL,
  date_naissance DATE        NOT NULL,
  race           VARCHAR(50) NOT NULL,
  sterilise      BOOLEAN     NOT NULL DEFAULT FALSE,
  client_id      INT,
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL
);

CREATE TABLE chats (
  id             INT AUTO_INCREMENT PRIMARY KEY,
  nom            VARCHAR(50) NOT NULL,
  date_naissance DATE        NOT NULL,
  race           VARCHAR(50) NOT NULL,
  sterilise      BOOLEAN     NOT NULL DEFAULT FALSE,
  client_id      INT,
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL
);

INSERT INTO clients (nom, prenom, date_naissance, pseudonyme) VALUES
  ('Dupont',  'Alice', '1990-04-12', 'alice_d'),
  ('Martin',  'Lucas', '1985-11-03', 'lucasm'),
  ('Bernard', 'Emma',  '2000-07-21', 'emmab'),
  ('Petit',   'Hugo',  '1978-02-28', 'hugo78');

INSERT INTO adresses (numero, rue, code_postal, commune) VALUES
  ('12',  'rue Nationale',        '59000', 'Lille'),
  ('5',   'avenue de la Marne',   '59200', 'Tourcoing'),
  ('48',  'boulevard Carnot',     '59100', 'Roubaix'),
  ('3bis','place du Général',     '59800', 'Lille');

INSERT INTO clients_adresses (client_id, adresse_id) VALUES
  (1, 1), (1, 4),   -- Alice a deux adresses
  (2, 2),
  (3, 3),
  (4, 4);           -- Hugo partage l'adresse 4 avec Alice

INSERT INTO chiens (nom, date_naissance, race, sterilise, client_id) VALUES
  ('Rex',   '2019-05-10', 'Berger allemand',   TRUE,  1),
  ('Filou', '2021-09-02', 'Jack Russell',      FALSE, 2),
  ('Nala',  '2020-01-15', 'Labrador',          TRUE,  3),
  ('Oslo',  '2023-03-30', 'Husky sibérien',    FALSE, 4);

INSERT INTO chats (nom, date_naissance, race, sterilise, client_id) VALUES
  ('Mistigri', '2018-06-01', 'Européen',     TRUE,  1),
  ('Luna',     '2022-10-14', 'Maine Coon',   FALSE, 3),
  ('Simba',    '2021-12-25', 'Bengal',       TRUE,  4);
```

Choix de modélisation :
- `clients_adresses` est une table d'association **plusieurs-à-plusieurs** : un client peut avoir plusieurs adresses, et une adresse peut être partagée.
- `chiens` et `chats` ont un `client_id` (propriétaire) en clé étrangère.
- `sterilise` est un `BOOLEAN` (stocké `0`/`1` par MySQL).

## 2. Dockerfile

```dockerfile
FROM mysql:8.4
ENV MYSQL_ROOT_PASSWORD=rootpass
# Les scripts .sql de ce dossier sont exécutés au premier démarrage du conteneur
COPY init.sql /docker-entrypoint-initdb.d/01-init.sql
EXPOSE 3306
```

Au **premier** démarrage (dossier de données vide), le point d'entrée de l'image officielle `mysql` exécute tous les fichiers `.sql`, `.sql.gz` et `.sh` de `/docker-entrypoint-initdb.d/`, par ordre alphabétique.

## 3. Construire l'image

```bash
cd exo-07
docker build -t kennel-db-image .
```

```
 1 warning found (use docker --debug to expand):
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "MYSQL_ROOT_PASSWORD") (line 2)
```

> Docker avertit qu'un mot de passe est écrit en dur dans l'image. Pour un exercice, c'est acceptable. En production, on retirerait la ligne `ENV` et on passerait le mot de passe au lancement : `docker run -e MYSQL_ROOT_PASSWORD=…`.

```bash
docker images kennel-db-image
```

```
REPOSITORY        TAG       IMAGE ID       CREATED        SIZE
kennel-db-image   latest    a7d222f380f4   1 second ago   812MB
```

## 4. Lancer un conteneur à partir de cette image

```bash
docker run -d --name kennel-db kennel-db-image
```

On attend que MySQL ait fini son initialisation (`docker logs -f kennel-db` jusqu'à `ready for connections … port: 3306`).

## 5. Vérifier le contenu

```bash
docker exec kennel-db mysql -uroot -prootpass -e "SHOW DATABASES;"
```

```
Database
information_schema
kennelDB
mysql
performance_schema
sys
```

```bash
docker exec kennel-db mysql -uroot -prootpass kennelDB -e "SHOW TABLES;"
```

```
Tables_in_kennelDB
adresses
chats
chiens
clients
clients_adresses
```

```bash
docker exec kennel-db mysql -uroot -prootpass kennelDB -e "SELECT * FROM clients;"
```

```
id	nom	prenom	date_naissance	pseudonyme
1	Dupont	Alice	1990-04-12	alice_d
2	Martin	Lucas	1985-11-03	lucasm
3	Bernard	Emma	2000-07-21	emmab
4	Petit	Hugo	1978-02-28	hugo78
```

```bash
docker exec kennel-db mysql -uroot -prootpass kennelDB -e "SELECT * FROM adresses;"
```

```
id	numero	rue	code_postal	commune
1	12	rue Nationale	59000	Lille
2	5	avenue de la Marne	59200	Tourcoing
3	48	boulevard Carnot	59100	Roubaix
4	3bis	place du Général	59800	Lille
```

Associations clients ↔ adresses (jointure) :

```bash
docker exec kennel-db mysql -uroot -prootpass kennelDB -e "
  SELECT c.pseudonyme, a.numero, a.rue, a.code_postal, a.commune
  FROM clients c
  JOIN clients_adresses ca ON ca.client_id = c.id
  JOIN adresses a ON a.id = ca.adresse_id
  ORDER BY c.id;"
```

```
pseudonyme	numero	rue	code_postal	commune
alice_d	12	rue Nationale	59000	Lille
alice_d	3bis	place du Général	59800	Lille
lucasm	5	avenue de la Marne	59200	Tourcoing
emmab	48	boulevard Carnot	59100	Roubaix
hugo78	3bis	place du Général	59800	Lille
```

```bash
docker exec kennel-db mysql -uroot -prootpass kennelDB -e "SELECT * FROM chiens;"
```

```
id	nom	date_naissance	race	sterilise	client_id
1	Rex	2019-05-10	Berger allemand	1	1
2	Filou	2021-09-02	Jack Russell	0	2
3	Nala	2020-01-15	Labrador	1	3
4	Oslo	2023-03-30	Husky sibérien	0	4
```

```bash
docker exec kennel-db mysql -uroot -prootpass kennelDB -e "SELECT * FROM chats;"
```

```
id	nom	date_naissance	race	sterilise	client_id
1	Mistigri	2018-06-01	Européen	1	1
2	Luna	2022-10-14	Maine Coon	0	3
3	Simba	2021-12-25	Bengal	1	4
```

La base `kennelDB` est créée et remplie dès le lancement du conteneur, sans aucune commande manuelle.

---

## Nettoyage

```bash
docker rm -f kennel-db
```
