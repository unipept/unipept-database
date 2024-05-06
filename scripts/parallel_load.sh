shopt -s expand_aliases

# Define PSQL connection parameters
export DB_USER="unipept"
export DB_PASSWORD="unipept"
export DB_NAME="unipept"

dir="$1"

function load_table() {
    file=$1
    tbl=`echo $file | sed "s/.tsv.lz4//"`
    echo "lz4catting - LOAD DATA LOCAL INFILE '$file' INTO TABLE $tbl"

    # Remove the last two columns of the peptides file
    {
    if [ "$tbl" == "peptides" ]
    then
        lz4cat $file | awk 'BEGIN {FS = OFS = "\t"} {NF-=2; print}' -
    else
        lz4cat $file
    fi
    } | PGPASSWORD=$DB_PASSWORD psql -U $DB_USER -c "COPY $DB_NAME.$tbl FROM STDIN WITH (FORMAT TEXT, DELIMITER E'\t', HEADER false, NULL '\N');" 2>&1
}

export -f load_table

cd "$dir"

parallel load_table ::: *.tsv.lz4

cd "-"

echo "done"
