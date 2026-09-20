use std::{
    fs,
    path::PathBuf,
    process::{Command, Output, Stdio}
};

/// Runs uniprot-parser-tryptic on the fixture entries and returns its output with the directory it
/// wrote to.
fn run(test: &str, min: &str, max: &str) -> (Output, PathBuf) {
    let dir = fixtures::temp_dir(&format!("uniprot-parser-tryptic-{test}"));
    // The binary opens its output files without creating them.
    fs::write(dir.join("uniprot_entries.tsv"), "").unwrap();
    fs::write(dir.join("peptides.tsv"), "").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_uniprot-parser-tryptic"))
        .arg("--taxa")
        .arg(fixtures::path("taxons.tsv"))
        .arg("--uniprot-entries")
        .arg(dir.join("uniprot_entries.tsv"))
        .arg("--peptides")
        .arg(dir.join("peptides.tsv"))
        .args(["--peptide-min", min, "--peptide-max", max, "--threads", "1"])
        .stdin(Stdio::from(fs::File::open(fixtures::path("uniprot_sprot.dat")).unwrap()))
        .output()
        .unwrap();

    (output, dir)
}

#[test]
fn test_writes_the_expected_tables() {
    let (output, dir) = run("tables", "5", "50");

    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    // The same table uniprot-parser writes: both binaries feed the same uniprot_entries.tsv.
    assert_eq!(
        fs::read_to_string(dir.join("uniprot_entries.tsv")).unwrap(),
        fs::read_to_string(fixtures::path("uniprot_entries.tsv")).unwrap()
    );
    assert_eq!(
        fs::read_to_string(dir.join("peptides.tsv")).unwrap(),
        fs::read_to_string(fixtures::path("peptides.tsv")).unwrap()
    );
}

/// The UMGAP steps read this table by position: column 2 is the sequence with every I as an L,
/// column 3 the sequence as it is, then the entry, the annotations and the taxon.
#[test]
fn test_peptides_columns() {
    let table = fs::read_to_string(fixtures::path("peptides.tsv")).unwrap();
    let row: Vec<&str> = table.lines().next().unwrap().split('\t').collect();

    assert!(table.lines().all(|row| row.split('\t').count() == 6));
    assert_eq!(row, ["1", "TAYLAK", "TAYIAK", "1", "GO:0009279;EC:1.1.1.1;IPR:IPR016364", "8501"]);
}

#[test]
fn test_the_length_limits_leave_out_peptides() {
    let (output, dir) = run("limits", "7", "10");

    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let kept: Vec<usize> = fs::read_to_string(dir.join("peptides.tsv"))
        .unwrap()
        .lines()
        .map(|row| row.split('\t').nth(2).unwrap().len())
        .collect();

    assert!(!kept.is_empty());
    assert!(kept.iter().all(|length| (7..=10).contains(length)), "{kept:?}");
}
