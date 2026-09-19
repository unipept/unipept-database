use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output}
};

/// Runs taxdmp-parser on a names/nodes pair and returns its output with the directory it wrote to.
fn run(test: &str, names: &Path, nodes: &Path) -> (Output, PathBuf) {
    let dir = fixtures::temp_dir(&format!("taxdmp-parser-{test}"));
    // The binary opens its output files without creating them.
    fs::write(dir.join("taxons.tsv"), "").unwrap();
    fs::write(dir.join("lineages.tsv"), "").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_taxdmp-parser"))
        .arg("--names")
        .arg(names)
        .arg("--nodes")
        .arg(nodes)
        .arg("--taxa")
        .arg(dir.join("taxons.tsv"))
        .arg("--lineages")
        .arg(dir.join("lineages.tsv"))
        .output()
        .unwrap();

    (output, dir)
}

#[test]
fn test_writes_the_expected_tables() {
    let (output, dir) = run("tables", &fixtures::path("names.dmp"), &fixtures::path("nodes.dmp"));

    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(fs::read(dir.join("taxons.tsv")).unwrap(), fs::read(fixtures::path("taxons.tsv")).unwrap());
    assert_eq!(fs::read(dir.join("lineages.tsv")).unwrap(), fs::read(fixtures::path("lineages.tsv")).unwrap());
}

#[test]
fn test_rejects_a_rank_it_does_not_know() {
    let dir = fixtures::temp_dir("taxdmp-parser-rank");
    let nodes = fs::read_to_string(fixtures::path("nodes.dmp")).unwrap().replacen("\tno rank\t", "\tclade\t", 1);
    fs::write(dir.join("nodes.dmp"), nodes).unwrap();

    let (output, _) = run("rank", &fixtures::path("names.dmp"), &dir.join("nodes.dmp"));

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("Unable to parse Taxon Rank"));
}

#[test]
fn test_an_invalid_taxon_invalidates_its_descendants() {
    let dir = fixtures::temp_dir("taxdmp-parser-invalid");
    let names = fs::read_to_string(fixtures::path("names.dmp")).unwrap().replace(
        "8500\t|\tCrocodylus\t|\t\t|\tscientific name",
        "8500\t|\tuncultured Crocodylus\t|\t\t|\tscientific name"
    );
    fs::write(dir.join("names.dmp"), names).unwrap();

    let (output, out) = run("invalid", &dir.join("names.dmp"), &fixtures::path("nodes.dmp"));
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));

    let taxons = fs::read(out.join("taxons.tsv")).unwrap();
    let valid = |id: &str| {
        let row = taxons.split(|&b| b == b'\n').find(|row| row.starts_with(format!("{id}\t").as_bytes())).unwrap();
        row.last() == Some(&1)
    };
    assert!(valid("8493"));
    assert!(!valid("8500"));
    assert!(!valid("8501"));
}
