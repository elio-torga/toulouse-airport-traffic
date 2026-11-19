-- =====================================================================
-- 01_schema.sql — star schema for 35 years of French airport traffic
-- Source: DGAC "Trafic aérien commercial mensuel français" (data.gouv.fr, Licence Ouverte)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS staging;

DROP TABLE IF EXISTS fact_forecast, fact_route_traffic, fact_airport_traffic,
                     dim_route, dim_airport, dim_date CASCADE;

-- ---------------------------------------------------------------------
-- dim_date: one row per month. date_id = YYYYMM, the DGAC "ANMOIS" format.
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_id      integer  PRIMARY KEY,
    month_start  date     NOT NULL UNIQUE,
    year         smallint NOT NULL,
    month        smallint NOT NULL CHECK (month BETWEEN 1 AND 12),
    quarter      smallint NOT NULL CHECK (quarter BETWEEN 1 AND 4),
    month_name   text     NOT NULL,
    is_covid     boolean  NOT NULL      -- March 2020 to December 2021
);

INSERT INTO dim_date
SELECT to_char(d, 'YYYYMM')::int,
       d::date,
       extract(year FROM d),
       extract(month FROM d),
       extract(quarter FROM d),
       to_char(d, 'Mon'),
       d BETWEEN DATE '2020-03-01' AND DATE '2021-12-01'
FROM generate_series(DATE '1990-01-01', DATE '2030-12-01', interval '1 month') AS d;

-- ---------------------------------------------------------------------
-- dim_airport: French airports (from APT) and foreign airports (from PAP routes).
-- ---------------------------------------------------------------------
CREATE TABLE dim_airport (
    airport_id  serial  PRIMARY KEY,
    icao        char(4) NOT NULL UNIQUE,          -- LFBO = Toulouse-Blagnac
    name        text    NOT NULL,
    zone        text    NOT NULL CHECK (zone IN ('METRO', 'OVERSEAS', 'FOREIGN', 'AGGREGATE')),
    is_french   boolean GENERATED ALWAYS AS (zone IN ('METRO', 'OVERSEAS')) STORED
);

-- ---------------------------------------------------------------------
-- dim_route: one row per airport pair, in the DGAC order (see notice PAP).
-- ---------------------------------------------------------------------
CREATE TABLE dim_route (
    route_id      serial  PRIMARY KEY,
    route_code    char(9) NOT NULL UNIQUE,         -- e.g. LFBO_LEMD
    airport_1_id  integer NOT NULL REFERENCES dim_airport,
    airport_2_id  integer NOT NULL REFERENCES dim_airport,
    distance_km   integer,
    CHECK (airport_1_id <> airport_2_id)
);

-- ---------------------------------------------------------------------
-- fact_airport_traffic (series APT): complete monthly traffic per airport.
-- Grain: one airport, one month. The source of every total in this project.
-- ---------------------------------------------------------------------
CREATE TABLE fact_airport_traffic (
    date_id          integer       NOT NULL REFERENCES dim_date,
    airport_id       integer       NOT NULL REFERENCES dim_airport,
    pax_departing    integer       NOT NULL CHECK (pax_departing >= 0),
    pax_arriving     integer       NOT NULL CHECK (pax_arriving >= 0),
    pax_transit      integer       NOT NULL CHECK (pax_transit >= 0),
    pax_total        integer       GENERATED ALWAYS AS (pax_departing + pax_arriving + pax_transit) STORED,
    freight_dep_t    numeric(12,1) NOT NULL CHECK (freight_dep_t >= 0),
    freight_arr_t    numeric(12,1) NOT NULL CHECK (freight_arr_t >= 0),
    movements_pax    integer       NOT NULL CHECK (movements_pax >= 0),   -- mixed passenger/freight flights
    movements_cargo  integer       NOT NULL CHECK (movements_cargo >= 0),
    peq_reported     integer       NOT NULL,                              -- passenger-equivalents, as published
    PRIMARY KEY (date_id, airport_id)
);
-- The PK serves "all airports for a month"; this index serves "one airport over time".
CREATE INDEX idx_fat_airport_date ON fact_airport_traffic (airport_id, date_id);

-- ---------------------------------------------------------------------
-- fact_route_traffic (series PAP): monthly traffic per airport pair.
-- INCOMPLETE BY DESIGN: a route-month is published only if >= 3 operators fly it
-- and none has more than 85% of the traffic (French statistical secrecy rule).
-- ---------------------------------------------------------------------
CREATE TABLE fact_route_traffic (
    date_id          integer       NOT NULL REFERENCES dim_date,
    route_id         integer       NOT NULL REFERENCES dim_route,
    pax_local        integer       NOT NULL CHECK (pax_local >= 0),    -- passengers flying this O&D
    pax_onboard      integer       NOT NULL CHECK (pax_onboard >= 0),  -- passengers on board direct flights
    freight_local_t  numeric(12,1) NOT NULL CHECK (freight_local_t >= 0),
    services         integer       NOT NULL CHECK (services >= 0),     -- commercial services (with or without stop)
    movements        integer       NOT NULL CHECK (movements >= 0),    -- direct commercial movements
    PRIMARY KEY (date_id, route_id)
);
CREATE INDEX idx_frt_route_date ON fact_route_traffic (route_id, date_id);

-- ---------------------------------------------------------------------
-- fact_forecast: model output written back by python/forecast.py
-- ---------------------------------------------------------------------
CREATE TABLE fact_forecast (
    date_id       integer NOT NULL REFERENCES dim_date,
    airport_id    integer NOT NULL REFERENCES dim_airport,
    model         text    NOT NULL,
    pax_forecast  integer NOT NULL,
    lo80          integer NOT NULL,
    hi80          integer NOT NULL,
    lo95          integer NOT NULL,
    hi95          integer NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (date_id, airport_id, model)
);
