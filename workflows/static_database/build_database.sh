# Initialize the database
cat workflows/static_database/structure.sql | sqlite3 output.db

# Read all generated data into this database
zcat data/tables/ec_numbers.tsv.gz | sed "s/\t/$/g" | sqlite3 -csv -separator "$" output.db '.import /dev/stdin ec_numbers'
zcat data/tables/go_terms.tsv.gz | sed "s/\t/$/g" | sqlite3 -csv -separator "$" output.db '.import /dev/stdin go_terms'
zcat data/tables/interpro_entries.tsv.gz | sed "s/\t/$/g" | sqlite3 -csv -separator "$" output.db '.import /dev/stdin interpro_entries'
zcat data/tables/taxons.tsv.gz | sed "s/\t/$/g" | sqlite3 -csv -separator "$" output.db '.import /dev/stdin taxons'

# Compress the database before uploading it to a Github release
zip output.zip output.db
