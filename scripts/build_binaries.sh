#! /usr/bin/env bash

# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"

checkdep() {
    which $1 > /dev/null 2>&1 || hash $1 > /dev/null 2>&1 || {
        echo "Unipept database builder requires ${2:-$1} to be installed." >&2
        exit 1
    }
}

checkdep cargo "Rust Toolchain"

# Build binaries and copy them to the /helper_scripts folder
cd $CURRENT_LOCATION/helper_scripts/unipept-database-rs
cargo build --release

for BINARY in "functional-analysis" "lcas" "taxa-by-chunk" "taxons-lineages" "taxons-uniprots-tables" "write-to-chunk" "xml-parser"
do
  cp "./target/release/$BINARY" ..
done
