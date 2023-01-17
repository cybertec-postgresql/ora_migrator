EXTENSION = ora_migrator
DATA = ora_migrator--*.sql
DOCS = README.ora_migrator
REGRESS = install migrate check_results partitioning

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

all:
	@echo 'Nothing to be built.  Run "make install".'
