package storage;

import xml.*;

import java.io.*;
import java.util.stream.Collectors;

public class TabWriter implements UniprotObserver {
    private final BufferedWriter out;
    private final boolean verbose;
    private final String dbType;

    public TabWriter(
            OutputStream out,
            String dbType,
            boolean verbose
    ) throws IOException {
        this.out = new BufferedWriter(new OutputStreamWriter(out));
        this.dbType = dbType;
        this.verbose = verbose;

        // Write header to output file
        this.out.write(String.join("\t", new String[]{
                "Entry",
                "Sequence",
                "Protein names",
                "Version (entry)",
                "EC number",
                "Gene ontology IDs",
                "Cross-reference (InterPro)",
                "Cross-reference (KEGG)",
                "Status",
                "Organism ID"
        }) + "\n");
    }

    @Override
    public void handleEntry(UniprotEntry entry) {
        try {
            String line = String.join("\t", new String[]{
                    entry.getUniprotAccessionNumber(),
                    entry.getSequence(),
                    entry.getName(),
                    String.valueOf(entry.getVersion()),
                    entry.getECReferences().stream().map(UniprotECRef::getId).collect(Collectors.joining(";")),
                    entry.getGOReferences().stream().map(UniprotGORef::getId).collect(Collectors.joining(";")),
                    entry.getInterProReferences().stream().map(UniprotInterProRef::getId).collect(Collectors.joining(";")),
                    entry.getKeggReferences().stream().map(UniprotKeggRef::getId).collect(Collectors.joining(";")),
                    this.dbType,
                    String.valueOf(entry.getTaxonId()),
            });

            if (verbose) {
                System.err.println("INFO VERBOSE: Writing tabular line: " + line);
            }

            this.out.write(line + "\n");
        } catch (IOException e) {
            System.err.println("Could not write to output stream.");
        }
    }

    @Override
    public void close() {
        try {
            this.out.close();
        } catch (IOException e) {
            System.err.println("Could not correctly close output stream.");
        }
    }
}
