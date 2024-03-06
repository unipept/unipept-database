shopt -s expand_aliases
alias zcat="pigz -cd"

export db=unipept
export user=root
export pass=unipept

dir="$1"

function load_table() {
    file=$1
    tbl=`echo $file | sed "s/.tsv.gz//"`
    echo "zcatting - LOAD DATA LOCAL INFILE '$file' INTO TABLE $tbl"
    zcat $file | mariadb --local-infile=1 -u$user -p$pass $db -e "LOAD DATA LOCAL INFILE '/dev/stdin' INTO TABLE $tbl;SHOW WARNINGS" 2>&1
}

export -f load_table

cd "$dir"

parallel load_table ::: *.tsv.gz

cd "-"

echo "done"
