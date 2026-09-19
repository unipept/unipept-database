use std::{
    fs,
    process::{Command, Stdio}
};

#[test]
fn test_writes_the_expected_tables() {
    let dir = std::env::temp_dir().join(format!("uniprot-parser-tryptic-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
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
        .args(["--peptide-min", "5", "--peptide-max", "50", "--threads", "1"])
        .stdin(Stdio::from(fs::File::open(fixtures::path("uniprot_sprot.dat")).unwrap()))
        .output()
        .unwrap();

    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(
        fs::read_to_string(dir.join("uniprot_entries.tsv")).unwrap(),
        fs::read_to_string(fixtures::path("uniprot_entries.tsv")).unwrap()
    );
    assert_eq!(
        fs::read_to_string(dir.join("peptides.tsv")).unwrap(),
        fs::read_to_string(fixtures::path("peptides.tsv")).unwrap()
    );
}
