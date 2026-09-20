use std::{fs, process::Command};

#[test]
fn test_counts_the_annotations_of_each_peptide() {
    // Peptides in sorted order. AAGGK is in three proteins, one of them without annotations, and
    // NONEK only in proteins without any, so it gets no row at all.
    let dir = fixtures::temp_dir("function-calculator");
    fs::write(
        dir.join("input.tsv"),
        concat!(
            "AAGGK\tGO:0009279;EC:1.1.1.1;IPR:IPR016364\n",
            "AAGGK\t\n",
            "AAGGK\tGO:0005515\n",
            "EK\tEC:1.1.1.1\n",
            "NONEK\t\n"
        )
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_function-calculator"))
        .arg("--input-file")
        .arg(dir.join("input.tsv"))
        .output()
        .unwrap();

    // The keys of "data" come out sorted, and every row is followed by an empty line.
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        concat!(
            r#"AAGGK	{"num":{"all":3,"EC":1,"GO":2,"IPR":1},"data":{"EC:1.1.1.1":1,"GO:0005515":1,"GO:0009279":1,"IPR:IPR016364":1}}"#,
            "\n\n",
            r#"EK	{"num":{"all":1,"EC":1,"GO":0,"IPR":0},"data":{"EC:1.1.1.1":1}}"#,
            "\n\n"
        )
    );
}
