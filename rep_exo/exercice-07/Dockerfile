FROM mysql:8.4

ENV MYSQL_DATABASE=kennelDB

# Every .sql / .sh file in this folder runs (alphabetical order) on the first start, when the data directory is empty
COPY init.sql /docker-entrypoint-initdb.d/01-init.sql
