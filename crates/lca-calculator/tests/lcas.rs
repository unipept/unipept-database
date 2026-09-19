use std::{
    io::Write,
    process::{Command, Stdio}
};

#[test]
fn test_calculates_the_lowest_common_ancestor() {
    // Sequences in sorted order, each with the taxa of the proteins that contain it.
    let input = [
        ("AAGGK", "8501 8502 8503 9"), // three Crocodylus species and Buchnera aphidicola
        ("CROCK", "8501 8502 8503"),   // three Crocodylus species
        ("HELOK", "8553"),             // Heloderma sp., an invalid species
        ("NILOK", "8501")              // Crocodylus niloticus only
    ]
    .iter()
    .flat_map(|(sequence, taxa)| taxa.split(' ').map(move |taxon| format!("{sequence}\t{taxon}\n")))
    .collect::<String>();

    let mut child = Command::new(env!("CARGO_BIN_EXE_lca-calculator"))
        .arg("--input-file")
        .arg(fixtures::path("lineages.tsv"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let output = child.wait_with_output().unwrap();

    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), "AAGGK\t1\nCROCK\t8500\nHELOK\t8550\nNILOK\t8501\n");
}
