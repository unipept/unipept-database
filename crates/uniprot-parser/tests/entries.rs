use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output, Stdio}
};

/// Runs uniprot-parser on a .dat file and returns its output with the directory it wrote to.
fn run(test: &str, dat: &Path, threads: &str) -> (Output, PathBuf) {
    let dir = fixtures::temp_dir(&format!("uniprot-parser-{test}"));
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
    let (_, dir) = run("columns", &fixtures::path("uniprot_sprot.dat"), "1");
    let table = fs::read_to_string(dir.join("uniprot_entries.tsv")).unwrap();
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

/// The pipeline parses with several threads, where a bad entry stops the reader while the workers
/// are still sending.
#[test]
fn test_a_malformed_entry_is_an_error_with_several_threads() {
    let dir = fixtures::temp_dir("uniprot-parser-malformed-threads");
    let dat = fs::read_to_string(fixtures::path("uniprot_sprot.dat")).unwrap().replacen(
        "UniProtKB/Swiss-Prot.",
        "UniProtKB/Unknown.",
        1
    );
    fs::write(dir.join("malformed.dat"), dat).unwrap();

    let (output, _) = run("malformed-threads", &dir.join("malformed.dat"), "4");

    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(!output.status.success());
    assert!(stderr.contains("Unknown database type"), "{stderr}");
    assert!(!stderr.contains("panicked"), "{stderr}");
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

/// The two bytes of a separator, and the newline before them, can fall on either side of a chunk
/// boundary. The padding puts a separator at the last byte of a chunk, and at the first.
#[test]
fn test_a_separator_on_a_chunk_boundary() {
    const CHUNK: usize = 64 * 1024;
    let entries = fs::read_to_string(fixtures::path("uniprot_sprot.dat")).unwrap().repeat(40);
    let expected = rows_without_id(&fs::read_to_string(fixtures::path("uniprot_entries.tsv")).unwrap());

    // The first separator line after one chunk, as the offset of its first slash.
    let separator = entries[CHUNK..].find("\n//\n").unwrap() + CHUNK + 1;

    // The first slash at the last byte of a chunk, and at the first: the second slash of the pair
    // then falls in the next chunk, where the reader has to look back at what it kept.
    for target in [CHUNK - 1, 0] {
        // The padding line itself is "CC   " plus its newline.
        let padding = (target + CHUNK - (separator + 6) % CHUNK) % CHUNK;
        let dir = fixtures::temp_dir(&format!("uniprot-parser-boundary-{target}"));
        let dat = format!("CC   {}\n{entries}", "x".repeat(padding));
        let at = separator + 6 + padding;
        assert_eq!(dat.as_bytes()[at], b'/', "the padding moved the separator");
        assert_eq!(at % CHUNK, target, "the first slash is not at offset {target} of a chunk");
        fs::write(dir.join("boundary.dat"), dat).unwrap();

        let (output, out) = run(&format!("boundary-{target}"), &dir.join("boundary.dat"), "4");

        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let mut rows = rows_without_id(&fs::read_to_string(out.join("uniprot_entries.tsv")).unwrap());
        assert_eq!(rows.len(), expected.len() * 40, "first slash at offset {target}");
        rows.dedup();
        assert_eq!(rows, expected, "first slash at offset {target}");
    }
}
