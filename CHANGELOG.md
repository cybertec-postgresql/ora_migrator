# Version 1.1.0 #

## Enhancements: ##

- Adapt to changes in `db_migrator` version 1.1.0.

- Make the extension non-relocatable.
  This simplifies the code, and it should be no problem: you can always drop
  and re-create the extension.

# Version 1.0.0, released 2023-02-08 #

## Enhancements: ##

- Add support for migrating partitioned tables.
  Patch by Florent Jardin.
