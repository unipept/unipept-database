# Rust Utils Workspace

This Rust workspace consists of a collection of libraries and executables used to process the UniProtKB 
database. It serves as a toolkit for parsing and transforming datasets from sources like UniProt and NCBI.

## Structure
The workspace includes:

### 📚 Libraries
- [`dat-parser`](./dat-parser/README.md): Parses UniProt `.dat` files to extract relevant metadata and annotations.
- `tables-generator`: Converts parsed data into tables for SA or database construction.
- `ncbi`: Provides some NCBI-specific structs for taxa and their current ranks. If NCBI updates 
their ranks, only this library will need to be updated.
- `utils`: Shared utility functions and helper tools used across the pipeline.

### ⚙️ Executables
- `function-calculator`: Performs functional aggregation of sequences.
- `lca-calculator`: Computes the Lowest Common Ancestor (LCA) for taxonomic entries.
- `taxdmp-parser`: Parses NCBI `taxdump` files.
- `uniprot-parser`: Parses UniProt `dat` files and returns structured entry data.
- `uniprot-parser-tryptic`: Parses UniProt `dat` files and returns structured entry and (tryptic) sequence data.

## 🛠️ Building the Workspace
To build everything in this workspace:
```sh
cargo build --release
```

### Build a Specific Package
From the root directory, run:
```sh
cargo build -p <package_name>
```
Replace `<package_name>` with the name of any crate, such as `dat-parser`.
