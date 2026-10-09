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
