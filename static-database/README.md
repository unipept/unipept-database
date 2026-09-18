# Static database

The schema of the SQLite database that the Unipept Desktop application reads. `structure.sql`
creates the tables and `init_virtual_tables.sql` adds the FTS5 table that makes a search on a taxon
name fast. `version.txt` records the data the schema was last changed for.

The application does not read this directory. It downloads the `unipept-static-db-<date>.zip` asset
that `.github/workflows/static_database.yml` publishes every month.

That workflow does not build the database from the files here: it republishes an existing zip under
a new date. Changing the schema therefore has no effect on what the application receives.
