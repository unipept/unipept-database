use std::{
    fs,
    process::{Command, Stdio}
};

/// Both are reachable from the pipeline: a step can hand over an empty table, and a taxon that the
/// UniProt entry names may be missing from the taxon dump the lineages were built from.
#[test]
fn test_reads_input_the_lineages_do_not_cover() {
    assert_eq!(run("empty", ""), "");
    assert_eq!(run("unknown", "SEQK\t99999999\n"), "SEQK\t1\n");
    assert_eq!(run("partly-unknown", "SEQK\t99999999\nSEQK\t8501\n"), "SEQK\t8501\n");
}

#[test]
fn test_calculates_the_lowest_common_ancestor() {
    // Sequences in sorted order, each with the taxa of the proteins that contain it.
    let input = [
        ("AAGGK", "8501 8502 8503 9"), // three Crocodylus species and Buchnera aphidicola
        ("CROCK", "8501 8502 8503"),   // three Crocodylus species: the genus is their ancestor
        ("GENUK", "8500 8501"),        // a genus and one of its species: a genus does not pull the answer up
        ("HELOK", "8553"),             // Heloderma sp.: invalid, so its lineage is negative below the genus
        ("NILOK", "8501")              // Crocodylus niloticus only
    ]
    .iter()
    .flat_map(|(sequence, taxa)| taxa.split(' ').map(move |taxon| format!("{sequence}\t{taxon}\n")))
    .collect::<String>();

    assert_eq!(run("lcas", &input), "AAGGK\t1\nCROCK\t8500\nGENUK\t8501\nHELOK\t8550\nNILOK\t8501\n");
}

/// Runs lca-calculator over the fixture lineages and returns what it wrote.
///
/// Through a file: the binary writes a line per sequence, and a pipe both ways can deadlock.
fn run(test: &str, input: &str) -> String {
    let dir = fixtures::temp_dir(&format!("lca-calculator-{test}"));
    fs::write(dir.join("sequences.tsv"), input).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_lca-calculator"))
        .arg("--input-file")
        .arg(fixtures::path("lineages.tsv"))
        .stdin(Stdio::from(fs::File::open(dir.join("sequences.tsv")).unwrap()))
        .output()
        .unwrap();

    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap()
}
