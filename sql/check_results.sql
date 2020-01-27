SET client_min_messages = WARNING;

\dn

\d testschema1.*
\d testschema2.*

/* more version independent than \df */
SELECT proname, prorettype::regtype, proargtypes::regtype[]
FROM pg_catalog.pg_proc
WHERE pronamespace = 'testschema1'::regnamespace
ORDER BY proname;

SELECT * FROM testschema1.tab1 ORDER BY id;

SELECT * FROM testschema1.tab2 ORDER BY id;

SELECT * FROM testschema1.view1 ORDER BY vc, c;

SELECT * FROM testschema2.tab3 ORDER BY id;
