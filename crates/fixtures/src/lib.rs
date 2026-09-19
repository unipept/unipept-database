//! The shared test corpus: the pipeline's inputs, and the tables it makes of them.
//!
//! - `names.dmp`, `nodes.dmp`: the taxa of unipept-api's `fixtures` crate plus every ancestor, so
//!   each parent chain reaches the root. The rows are copied from the NCBI dump; `nodes.dmp` holds
//!   the ranks after the mapping in `pipelines/lib/sources.sh`, which is what `taxdmp-parser` reads.
//! - `uniprot_sprot.dat`: synthetic entries. P00001 to P00013 carry the accession, taxon, sequence
//!   and annotations of unipept-api's `proteins.tsv`. P00014 names a taxon outside the corpus.
//! - `taxons.tsv`, `lineages.tsv`: what `taxdmp-parser` writes for the dumps. The rows for the
//!   API's taxa are the rows of the API's `taxons.tsv` and `lineages.tsv`.
//! - `uniprot_entries.tsv`, `proteomes.tsv`: what `uniprot-parser --threads 1` writes for the
//!   entries. P00014 is not in them.
//! - `peptides.tsv`: what `uniprot-parser-tryptic --threads 1 --peptide-min 5 --peptide-max 50`
//!   writes for the entries. Its `uniprot_entries.tsv` is the one above.
//!
//! To regenerate the outputs, run the binaries on the inputs and check the difference by eye.
//! The fifth column of `taxons.tsv` is a raw `0x01`/`0x00` byte, not text.

use std::path::PathBuf;

/// A directory for a test to write in. The process id keeps the tests of one binary apart.
pub fn temp_dir(test: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("{test}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a writable temporary directory");
    dir
}

/// The path of a file in the corpus, for tests that pass files to a binary.
pub fn path(file: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("data").join(file)
}
