-- Initialize databases for all Tractus-X components
-- Runs once on first startup of the shared PostgreSQL container

CREATE DATABASE ih;
CREATE DATABASE bdrs;
CREATE DATABASE edc_provider;
CREATE DATABASE edc_consumer;
CREATE DATABASE issuer;

-- Grant privileges to default user
GRANT ALL PRIVILEGES ON DATABASE ih TO "user";
GRANT ALL PRIVILEGES ON DATABASE bdrs TO "user";
GRANT ALL PRIVILEGES ON DATABASE edc_provider TO "user";
GRANT ALL PRIVILEGES ON DATABASE edc_consumer TO "user";
GRANT ALL PRIVILEGES ON DATABASE issuer TO "user";

-- BDRS uses a separate user (matches production config)
CREATE USER bdrs WITH PASSWORD 'bdrspassword';
GRANT ALL PRIVILEGES ON DATABASE bdrs TO bdrs;
ALTER DATABASE bdrs OWNER TO bdrs;
