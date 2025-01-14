-- CREATE USER debezium WITH ENCRYPTED PASSWORD 'password';
-- CREATE ROLE debezium WITH LOGIN REPLICATION PASSWORD 'password';
-- GRANT ALL PRIVILEGES ON DATABASE users TO debezium;
--
-- \c users
CREATE TABLE Users
(
    id         serial PRIMARY KEY,
    name       varchar(255) NOT NULL,
    created_at timestamp DEFAULT current_timestamp
);

INSERT INTO Users(id, name)
VALUES (1, 'George Delis'),
       (2, 'Vasiliki Georgila'),
       (3, 'Panos Sideris'),
       (4, 'John Karnezis');