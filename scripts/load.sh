#!/bin/bash
# extracts all .tsv.gz files, imports them into the unipept database
# and removes the files

# Directory from which the .tsv.gz files should be read and parsed (= first argument to this script).
dir="$1"
db=unipept

function print {
    echo $(date -u) $1
}

cd "$dir"

for file in *.tsv.lz4
do
    print $file
    tbl=`echo $file | sed "s/.tsv.lz4//"`
    echo "zcatting - LOAD DATA LOCAL INFILE '$file' INTO TABLE $tbl"
    zcat $file | mariadb  --local-infile=1 -uunipept -punipept $db -e "LOAD DATA LOCAL INFILE '/dev/stdin' INTO TABLE $tbl;SHOW WARNINGS" 2>&1
done
print "done"

cd -
