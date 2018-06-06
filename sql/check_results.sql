SET client_min_messages = WARNING;

\dn

\d testschema1.*
\d testschema2.*

/* more version independent than \df */
SELECT proname, prorettype::regtype, proargtypes::regtype[]
FROM pg_catalog.pg_proc
WHERE pronamespace = 'testschema1'::regnamespace
ORDER BY proname;

SELECT * FROM testschema1.tab1;

SELECT * FROM testschema1.tab2;

SELECT * FROM testschema1.view1;

SELECT * FROM testschema2.tab3;
