use std::{fs, process::Command};

#[test]
fn test_counts_the_annotations_of_each_peptide() {
    let dir = std::env::temp_dir().join(format!("function-calculator-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    // Peptides in sorted order, each with the annotations of one protein that contains it.
    fs::write(
        dir.join("input.tsv"),
        "AAGGK\tGO:0009279;EC:1.1.1.1;IPR:IPR016364\nAAGGK\t\nAAGGK\tGO:0005515\nEK\tEC:1.1.1.1\nNONEK\t\n"
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_function-calculator"))
        .arg("--input-file")
        .arg(dir.join("input.tsv"))
        .output()
        .unwrap();

    assert!(output.status.success());
    let rows: Vec<String> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .filter(|row| !row.is_empty())
        .map(String::from)
        .collect();
    assert_eq!(rows, [
        r#"AAGGK	{"num":{"all":3,"EC":1,"GO":2,"IPR":1},"data":{"EC:1.1.1.1":1,"GO:0005515":1,"GO:0009279":1,"IPR:IPR016364":1}}"#,
        r#"EK	{"num":{"all":1,"EC":1,"GO":0,"IPR":0},"data":{"EC:1.1.1.1":1}}"#
    ]);
}
