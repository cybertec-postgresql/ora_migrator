EXTENSION = ora_migrator
DATA = ora_migrator--1.0.sql
DOCS = README.ora_migrator

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

all:
	@echo 'Nothing to be built.  Run "make install".'
