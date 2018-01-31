SET client_min_messages = WARNING;

\dn

\d testschema1.*
\d testschema2.*

\df testschema1.*

SELECT * FROM testschema1.tab1;

SELECT * FROM testschema1.tab2;

SELECT * FROM testschema1.view1;

SELECT * FROM testschema2.tab3;
