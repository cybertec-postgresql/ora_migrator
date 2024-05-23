/*
 * Script to create the data for the regression tests.
 *
 * This scripts has to be run from sqlplus by a user
 * with the CREATE USER privilege.
 */

/* variables that can be changed */
DEFINE tablespace = USERS

/* clean up from previous installation */
DROP USER testschema1 CASCADE;
DROP USER testschema2 CASCADE;
DROP USER testschema3 CASCADE;

/* create users and schemas */
CREATE USER testschema1 IDENTIFIED BY good_password
   DEFAULT TABLESPACE &tablespace
   QUOTA UNLIMITED ON &tablespace;

CREATE USER testschema2 IDENTIFIED BY good_password
   DEFAULT TABLESPACE &tablespace
   QUOTA UNLIMITED ON &tablespace;

CREATE USER testschema3 IDENTIFIED BY good_password
   DEFAULT TABLESPACE &tablespace
   QUOTA UNLIMITED ON &tablespace;

/* give permissions required for the migration */
GRANT CONNECT, CREATE ANY TABLE, CREATE ANY INDEX, CREATE VIEW,
      CREATE ANY TRIGGER, CREATE PROCEDURE, CREATE SEQUENCE, DROP ANY TABLE,
      DROP ANY TRIGGER, SELECT ANY TABLE, SELECT ANY DICTIONARY
   TO testschema1;

GRANT CONNECT, CREATE TABLE, CREATE VIEW, CREATE TRIGGER, CREATE PROCEDURE
   TO testschema2;

GRANT CONNECT, CREATE TABLE, CREATE VIEW, CREATE TRIGGER, CREATE PROCEDURE
   TO testschema3;

/* connect as "testschema1" to create some objects */
CONNECT testschema1/good_password

/* configure formats for the session */
ALTER SESSION SET NLS_NUMERIC_CHARACTERS='.,';
ALTER SESSION SET NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS BC';
ALTER SESSION SET NLS_TIMESTAMP_FORMAT='YYYY-MM-DD HH24:MI:SS.FF9 BC';
ALTER SESSION SET NLS_TIMESTAMP_TZ_FORMAT='YYYY-MM-DD HH24:MI:SS.FF9TZH:TZM BC';

CREATE TABLE tab1 (
   id         NUMBER(5)         CONSTRAINT tab1_pkey PRIMARY KEY,
   vc         VARCHAR2(30 CHAR) DEFAULT 'AT ' || sysdate,
   n          NUMBER(10)        CONSTRAINT tab1_n_null NOT NULL,
   bf         BINARY_FLOAT      CONSTRAINT tab1_bf_check CHECK (bf > 0),
   bd         BINARY_DOUBLE,
   d          DATE              CONSTRAINT tab1_d_null NOT NULL,
   ts         TIMESTAMP
) SEGMENT CREATION IMMEDIATE;

COMMENT ON TABLE tab1 IS 'The first test table';
COMMENT ON COLUMN tab1.id IS 'The primary key column';
COMMENT ON COLUMN tab1.bf IS 'A useless comment';

CREATE TABLE log (
   username   VARCHAR2(128 CHAR)        CONSTRAINT log_user_null NOT NULL,
   logts      TIMESTAMP WITH LOCAL TIME ZONE CONSTRAINT log_logts_null NOT NULL,
   table_name VARCHAR2(128 CHAR)        CONSTRAINT log_table_name_null NOT NULL,
   id         NUMBER                    CONSTRAINT log_id_null NOT NULL,
   CONSTRAINT log_pkey PRIMARY KEY (logts, username)
) SEGMENT CREATION IMMEDIATE;

CREATE TRIGGER tab1_trig
   BEFORE INSERT OR UPDATE ON tab1
   FOR EACH ROW
BEGIN
   INSERT INTO log (username, logts, table_name, id)
      VALUES (USER, CURRENT_TIMESTAMP, 'tab1', :NEW.id);
END;
/

INSERT INTO tab1 (id, vc, n, bf, bd, d, ts)
   VALUES (1, 'some text', 12345, 3.14, -2.718,
           '2018-01-26 00:00:00 AD',
           '2018-01-26 22:30:00.0 AD');

INSERT INTO tab1 (id, vc, n, bf, d)
   VALUES (2, NULL, 87654, 9.3452, '2017-12-29 12:00:00 AD');

COMMIT;

CREATE INDEX tab1_bf_bd_ind ON tab1(bf ASC, bd DESC);

CREATE INDEX tab1_d_exp_ind ON tab1(EXTRACT(day FROM d));

CREATE FUNCTION tomorrow(d DATE) RETURN DATE AS
BEGIN
   RETURN d + 1;
END;
/

CREATE TABLE tab2 (
   id        NUMBER(5) CONSTRAINT tab2_pkey PRIMARY KEY,
   tab1_id   NUMBER(5) CONSTRAINT tab2_tab1_id_null NOT NULL
                       CONSTRAINT tab2_fkey REFERENCES tab1(id),
   c         CLOB,
   b         BLOB
) SEGMENT CREATION IMMEDIATE;

GRANT SELECT, REFERENCES ON tab2 TO testschema2;

INSERT INTO tab2 (id, tab1_id, c, b)
   VALUES (1, 1, 'a long text', 'DEADBEEF');

INSERT INTO tab2 (id, tab1_id, b)
   VALUES (2, 1, 'DEADF00D');

COMMIT;

CREATE SEQUENCE seq1 INCREMENT BY 5 CACHE 10;

CREATE VIEW view1 AS
   SELECT tab1.vc, tab2.c
   FROM tab1 LEFT JOIN tab2 ON tab1.id = tab2.tab1_id;

/* this will fail because there is a zero byte in the data */
CREATE TABLE baddata (
   id     NUMBER(5) CONSTRAINT baddata_pkey PRIMARY KEY,
   value1 VARCHAR2(20 CHAR),
   value2 VARCHAR2(20 CHAR)
) SEGMENT CREATION IMMEDIATE;

INSERT INTO baddata (id, value1, value2)
   VALUES (1, 'contains' || chr(0) || 'zero', convert('schön korrupt', 'WE8ISO8859P1'));
INSERT INTO baddata (id, value1, value2)
   VALUES (2, NULL, NULL);
INSERT INTO baddata (id, value1, value2)
   VALUES (3, NULL, convert('böse', 'WE8ISO8859P1'));

COMMIT;

/* connect as "testschema2" to create some objects */
CONNECT testschema2/good_password

CREATE TABLE tab3 (
   id        NUMBER(5) CONSTRAINT tab3_pkey PRIMARY KEY,
   tab2_id   NUMBER(5) CONSTRAINT tab3_tab2_id_null NOT NULL
                       CONSTRAINT tab3_fkey REFERENCES testschema1.tab2(id) ON DELETE CASCADE,
   f         FLOAT(5),
   ids       INTERVAL DAY TO SECOND
);

GRANT SELECT ON tab3 TO testschema1;

INSERT INTO tab3 (id, tab2_id, f, ids)
   VALUES (1, 2, 2.5, INTERVAL '1 12:00:00' DAY TO SECOND);

INSERT INTO tab3 (id, tab2_id, f, ids)
   VALUES (2, 1, -1, INTERVAL '01:30' MINUTE TO SECOND);

COMMIT;

/* connect as "testschema3" to create some partitioned tables */
CONNECT testschema3/good_password

CREATE TABLE part1 (
   c1 NUMBER(5) NOT NULL,
   c2 VARCHAR2(100) NOT NULL
)
PARTITION BY LIST (c1) (
   PARTITION part1_a VALUES (1, 2, 3),
   PARTITION part1_b VALUES (4, 5),
   PARTITION part1_default VALUES (DEFAULT)
);

INSERT INTO part1 (c1, c2) VALUES (1, 'one');
INSERT INTO part1 (c1, c2) VALUES (5, 'five');
INSERT INTO part1 (c1, c2) VALUES (10, 'ten');

CREATE TABLE part2 (
   r1 NUMBER(5) NOT NULL,
   h1 VARCHAR2(100) NOT NULL,
   h2 TIMESTAMP NOT NULL
)
PARTITION BY RANGE (r1)
SUBPARTITION BY HASH (h1, h2) (
   PARTITION part2_a VALUES LESS THAN (10) (
      SUBPARTITION part2_a_1,
      SUBPARTITION part2_a_2,
      SUBPARTITION part2_a_3
   ),
   PARTITION part2_b VALUES LESS THAN (100) (
      SUBPARTITION part2_b_1,
      SUBPARTITION part2_b_2,
      SUBPARTITION part2_b_3
   ),
   PARTITION part2_c VALUES LESS THAN (MAXVALUE) (
      SUBPARTITION part2_c_1,
      SUBPARTITION part2_c_2,
      SUBPARTITION part2_c_3
   )
);

INSERT INTO part2 (r1, h1, h2)
   VALUES (1, 'something', to_timestamp('2023-01-01 13:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO part2 (r1, h1, h2)
   VALUES (1, 'other', to_timestamp('2023-01-01 23:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO part2 (r1, h1, h2)
   VALUES (50, 'something', to_timestamp('2023-01-01 13:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO part2 (r1, h1, h2)
   VALUES (50, 'other', to_timestamp('2023-01-01 23:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO part2 (r1, h1, h2)
   VALUES (500, 'something', to_timestamp('2023-01-01 13:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO part2 (r1, h1, h2)
   VALUES (500, 'other', to_timestamp('2023-01-01 23:00:00', 'YYYY-MM-DD HH24:MI:SS'));

CREATE TABLE part3 (
   c1 NUMBER(5),
   c2 VARCHAR2(100)
)
PARTITION BY HASH (c2)
SUBPARTITION BY LIST (c1) (
   PARTITION part3_a (
      SUBPARTITION part3_a_1 VALUES (1, 2, 3),
      SUBPARTITION part3_a_2 VALUES (4, 5, 6),
      SUBPARTITION part3_a_3 VALUES (7, 8, 9)
   ),
   PARTITION part3_b (
      SUBPARTITION part3_b_1 VALUES (1, 2, 3),
      SUBPARTITION part3_b_2 VALUES (4, 5, 6),
      SUBPARTITION part3_b_3 VALUES (7, 8, 9)
   ),
   PARTITION part3_c (
      SUBPARTITION part3_c_1 VALUES (1, 2, 3),
      SUBPARTITION part3_c_2 VALUES (4, 5, 6),
      SUBPARTITION part3_c_3 VALUES (DEFAULT)
   )
);

INSERT INTO part3 (c1, c2) VALUES (1, 'a');
INSERT INTO part3 (c1, c2) VALUES (5, 'a');
INSERT INTO part3 (c1, c2) VALUES (9, 'a');
INSERT INTO part3 (c1, c2) VALUES (1, 'b');
INSERT INTO part3 (c1, c2) VALUES (5, 'b');
INSERT INTO part3 (c1, c2) VALUES (9, 'b');
INSERT INTO part3 (c1, c2) VALUES (1, 'c');
INSERT INTO part3 (c1, c2) VALUES (5, 'c');
INSERT INTO part3 (c1, c2) VALUES (9, 'c');
INSERT INTO part3 (c1, c2) VALUES (1, 'd');
INSERT INTO part3 (c1, c2) VALUES (5, 'd');
INSERT INTO part3 (c1, c2) VALUES (9, 'd');
INSERT INTO part3 (c1, c2) VALUES (1, 'e');
INSERT INTO part3 (c1, c2) VALUES (5, 'e');
INSERT INTO part3 (c1, c2) VALUES (9, 'e');
INSERT INTO part3 (c1, c2) VALUES (1, 'f');
INSERT INTO part3 (c1, c2) VALUES (5, 'f');
INSERT INTO part3 (c1, c2) VALUES (9, 'f');

COMMIT;

QUIT
