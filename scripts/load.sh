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

for file in *.tsv.gz
do
    print $file
    tbl=`echo $file | sed "s/.tsv.gz//"`
    echo "zcatting - LOAD DATA LOCAL INFILE '$file' INTO TABLE $tbl"
    gzcat $file | mysql --local-infile=1 --user=unipept --password=unipept $db -e "LOAD DATA LOCAL INFILE '/dev/stdin' INTO TABLE $tbl;SHOW WARNINGS" 2>&1
done
print "done"

cd -
