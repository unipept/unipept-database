# UniProtKB `.dat` file format

This document describes the `.dat` file format offered by UniProtKB as an alternative to their XML format.

| Field Identifier | Description                                                  |
| ---------------- | ------------------------------------------------------------ |
| ID               | The name of this entry                                       |
| AC               | Accession number                                             |
| DT               | Date information                                             |
| DE               | Recommended name (full), EC number, alternative names (full & short)<br />Protein information is given at the top level, component information is nested in a “contains” block, domain information is nested in an “includes” block<br />`Includes` always comes before `Contains` |
| GN               | Gene information                                             |
| OS               | Organism scientific name (+ common name)                     |
| OC               | Organism lineage + taxons                                    |
| OX               | Organism Taxonomy DB reference                               |
| OH               | Organism host Taxonomy DB reference + names                  |
| RN               | References: ID                                               |
| RP               | References: scope                                            |
| RA               | References: citation author                                  |
| RT               | References: citation title                                   |
| RL               | References: citation                                         |
| CC               | Comment                                                      |
| DR               | DB reference                                                 |
| PE               | Protein existence                                            |
| FT               | Feature                                                      |
| SQ               | Sequence (info on first line, sequence itself on following lines) |
| //               | End of entry. Note that this is also included for the very last entry, so it is not just a separator *between* entries. |
