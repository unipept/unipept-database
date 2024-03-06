shopt -s expand_aliases

export db=unipept
export user=root
export pass=unipept

dir="$1"

function load_table() {
    file=$1
    tbl=`echo $file | sed "s/.tsv.lz4//"`
    echo "lz4catting - LOAD DATA LOCAL INFILE '$file' INTO TABLE $tbl"
    lz4 -dc $file | mysql --local-infile=1 -u$user -p$pass $db -e "LOAD DATA LOCAL INFILE '/dev/stdin' INTO TABLE $tbl;SHOW WARNINGS" 2>&1
}

export -f load_table

cd "$dir"

parallel load_table ::: *.tsv.lz4

cd "-"

echo "done"
