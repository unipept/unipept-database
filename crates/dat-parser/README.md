# `dat-parser`

`dat-parser` is a high-performance Rust library for parsing UniProtKB `.dat` files as an alternative to 
XML. The parser extracts all fields, relevant for Unipept, into structured Rust types and supports both 
single-threaded and multi-threaded modes.

## 📂 Input Format: UniProtKB `.dat`

The `.dat` format uses prefixed lines for structured biological information. Here's a quick overview of the 
fields parsed by this parser for Unipept:

| Field | Description                                    |
|-------|------------------------------------------------|
| `AC`  | Accession numbers                              |
| `DT`  | Date information                               |
| `DE`  | Description: Protein names, EC numbers         |
| `OX`  | Taxonomy cross-reference (NCBI)                |
| `DR`  | Database cross-references (GO, InterPro, etc.) |
| `SQ`  | Sequence info                                  |
| `//`  | End of entry marker                            |

Refer to [UniProtKB dat documentation](https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/docs/userman.htm) 
for full details and examples on all fields.
