# unipept-rs

This is a Rust package that implements custom tools for the Unipept database construction pipeline.

The main tools are located in [`/src/bin`](./src/bin). They can all be built in one go using:

```shell
cargo build --release
```

or, individually:

```shell
cargo build --release --bin <name>
```

## Tools

| Name                                                            | Description                                                                                                                         |
|-----------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| [`xml-parser`](./src/bin/xml-parser.rs)                         | Parser for the UniProtKB XML files from [Uniprot](https://www.uniprot.org/help/downloads).                                          |
| [`functional-analysis`](./src/bin/functional-analysis.rs)       | Counts and combines functional annotations of all lines that start with the same sequence ID, and summarises this in a JSON-object. |
| [`taxons-uniprots-tables`](./src/bin/taxons-uniprots-tables.rs) | Parse the Uniprot TSV-file into TSV tables.                                                                                         |
