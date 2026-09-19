use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output, Stdio}
};

/// Runs uniprot-parser on a .dat file and returns its output with the directory it wrote to.
fn run(test: &str, dat: &Path, threads: &str) -> (Output, PathBuf) {
    let dir = std::env::temp_dir().join(format!("uniprot-parser-{test}-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    // The binary opens its output files without creating them.
    fs::write(dir.join("uniprot_entries.tsv"), "").unwrap();
    fs::write(dir.join("proteomes.tsv"), "").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_uniprot-parser"))
        .arg("--taxa")
        .arg(fixtures::path("taxons.tsv"))
        .arg("--uniprot-entries")
        .arg(dir.join("uniprot_entries.tsv"))
        .arg("--proteomes")
        .arg(dir.join("proteomes.tsv"))
        .args(["--threads", threads])
        .stdin(Stdio::from(fs::File::open(dat).unwrap()))
        .output()
        .unwrap();

    (output, dir)
}

/// The rows of a table, sorted and without the running id, which depends on the parse order.
fn rows_without_id(table: &str) -> Vec<String> {
    let mut rows: Vec<String> = table.lines().map(|row| row.split_once('\t').unwrap().1.to_string()).collect();
    rows.sort();
    rows
}

#[test]
fn test_writes_the_expected_tables() {
    let (output, dir) = run("tables", &fixtures::path("uniprot_sprot.dat"), "1");

    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(
        fs::read_to_string(dir.join("uniprot_entries.tsv")).unwrap(),
        fs::read_to_string(fixtures::path("uniprot_entries.tsv")).unwrap()
    );
    assert_eq!(
        fs::read_to_string(dir.join("proteomes.tsv")).unwrap(),
        fs::read_to_string(fixtures::path("proteomes.tsv")).unwrap()
    );
}

/// sa-builder reads columns 2, 4, 7 and 8, and the OpenSearch loader columns 2 to 8, by position.
#[test]
fn test_uniprot_entries_columns() {
    let table = fs::read_to_string(fixtures::path("uniprot_entries.tsv")).unwrap();
    let first: Vec<&str> = table.lines().next().unwrap().split('\t').collect();

    assert!(table.lines().all(|row| row.split('\t').count() == 8));
    assert_eq!(first, [
        "1",
        "P00001",
        "1",
        "8501",
        "swissprot",
        "Synthetic protein 1",
        "MKTAYIAKQRAWDIQNGKVSTLNETVGENYSAKAAGGKLHCDMPTFAKDEFRGISVNDAWEK",
        "EC:1.1.1.1;GO:0009279;IPR:IPR016364"
    ]);
}

#[test]
fn test_threaded_and_sequential_parsing_agree() {
    let (output, dir) = run("threaded", &fixtures::path("uniprot_sprot.dat"), "4");

    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(
        rows_without_id(&fs::read_to_string(dir.join("uniprot_entries.tsv")).unwrap()),
        rows_without_id(&fs::read_to_string(fixtures::path("uniprot_entries.tsv")).unwrap())
    );
}

#[test]
fn test_a_malformed_entry_is_an_error() {
    let dir = std::env::temp_dir().join(format!("uniprot-parser-malformed-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let dat = fs::read_to_string(fixtures::path("uniprot_sprot.dat")).unwrap().replacen(
        "UniProtKB/Swiss-Prot.",
        "UniProtKB/Unknown.",
        1
    );
    fs::write(dir.join("malformed.dat"), dat).unwrap();

    let (output, _) = run("malformed", &dir.join("malformed.dat"), "1");

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("Unknown database type"));
}
