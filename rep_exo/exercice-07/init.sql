-- kennelDB initialization script
-- Executed automatically by the MySQL image on first start (/docker-entrypoint-initdb.d)

CREATE DATABASE IF NOT EXISTS kennelDB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE kennelDB;

CREATE TABLE client (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  nom           VARCHAR(100) NOT NULL,
  prenom        VARCHAR(100) NOT NULL,
  date_naissance DATE        NOT NULL,
  pseudonyme    VARCHAR(50)  NOT NULL UNIQUE
);

CREATE TABLE adresse (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  numero      VARCHAR(10)  NOT NULL,
  rue         VARCHAR(255) NOT NULL,
  code_postal VARCHAR(10)  NOT NULL,
  commune     VARCHAR(100) NOT NULL
);

-- Many-to-many: a client can have several addresses, an address can be shared
CREATE TABLE client_adresse (
  client_id  INT NOT NULL,
  adresse_id INT NOT NULL,
  PRIMARY KEY (client_id, adresse_id),
  CONSTRAINT fk_ca_client  FOREIGN KEY (client_id)  REFERENCES client(id)  ON DELETE CASCADE,
  CONSTRAINT fk_ca_adresse FOREIGN KEY (adresse_id) REFERENCES adresse(id) ON DELETE CASCADE
);

CREATE TABLE chien (
  id             INT AUTO_INCREMENT PRIMARY KEY,
  nom            VARCHAR(100) NOT NULL,
  date_naissance DATE         NOT NULL,
  race           VARCHAR(100) NOT NULL,
  sterilise      BOOLEAN      NOT NULL DEFAULT FALSE,
  client_id      INT NULL,
  CONSTRAINT fk_chien_client FOREIGN KEY (client_id) REFERENCES client(id) ON DELETE SET NULL
);

CREATE TABLE chat (
  id             INT AUTO_INCREMENT PRIMARY KEY,
  nom            VARCHAR(100) NOT NULL,
  date_naissance DATE         NOT NULL,
  race           VARCHAR(100) NOT NULL,
  sterilise      BOOLEAN      NOT NULL DEFAULT FALSE,
  client_id      INT NULL,
  CONSTRAINT fk_chat_client FOREIGN KEY (client_id) REFERENCES client(id) ON DELETE SET NULL
);

INSERT INTO client (nom, prenom, date_naissance, pseudonyme) VALUES
  ('Dupont',  'Alice',  '1990-04-12', 'alice_d'),
  ('Martin',  'Bob',    '1985-11-03', 'bobby'),
  ('Durand',  'Chloé',  '2000-07-25', 'chloe25'),
  ('Lefebvre','David',  '1978-01-30', 'dav_lef');

INSERT INTO adresse (numero, rue, code_postal, commune) VALUES
  ('12',  'rue de la République', '69002', 'Lyon'),
  ('3bis','avenue Jean Jaurès',   '31000', 'Toulouse'),
  ('45',  'boulevard Voltaire',   '75011', 'Paris'),
  ('8',   'chemin des Vignes',    '33000', 'Bordeaux');

INSERT INTO client_adresse (client_id, adresse_id) VALUES
  (1, 1),
  (2, 1),   -- Alice and Bob share the same address
  (2, 2),   -- Bob has a second address
  (3, 3),
  (4, 4);

INSERT INTO chien (nom, date_naissance, race, sterilise, client_id) VALUES
  ('Rex',    '2019-05-10', 'Berger Allemand',    TRUE,  1),
  ('Médor',  '2021-02-14', 'Labrador',           FALSE, 2),
  ('Pixel',  '2023-08-01', 'Jack Russell',       FALSE, 3),
  ('Oslo',   '2017-12-24', 'Husky Sibérien',     TRUE,  4);

INSERT INTO chat (nom, date_naissance, race, sterilise, client_id) VALUES
  ('Minou',  '2020-03-15', 'Européen',           TRUE,  1),
  ('Félix',  '2022-06-30', 'Maine Coon',         FALSE, 3),
  ('Luna',   '2018-09-09', 'Siamois',            TRUE,  4);
