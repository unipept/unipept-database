package tsv;

import xml.*;

import java.io.*;
import java.util.HashMap;
import java.util.Map;
import java.util.stream.Stream;

public class UniprotTabParser {
    public void parse(
        int peptideMinLength,
        int peptideMaxLength,
        InputStream input,
        UniprotObserver observer
    ) throws IOException {
        BufferedReader reader = new BufferedReader(new InputStreamReader(input));

        String line = reader.readLine().trim();
        String[] header = Stream.of(line.split("\t")).map(String::trim).toArray(String[]::new);

        Map<String, Integer> headerMap = new HashMap<String, Integer>();
        for (int i = 0; i < header.length; i++) {
            headerMap.put(header[i], i);
        }

        line = reader.readLine();

        while (line != null) {
            String[] fields = line.trim().split("\t");

            // We need to emit one new UniprotEntry per line in the input
            UniprotEntry entry = new UniprotEntry(fields[headerMap.get("Status")].trim(), peptideMinLength, peptideMaxLength);

            // Now convert all fields into the correct Uniprot entry properties
            entry.setUniprotAccessionNumber(fields[headerMap.get("Entry")]);
            entry.setSequence(fields[headerMap.get("Sequence")].trim());

            entry.setRecommendedName(fields[headerMap.get("Protein names")].trim());
            // Todo, does not always need to be set?
            // entry.setSubmittedName("name");

            entry.setVersion(Integer.parseInt(fields[headerMap.get("Version (entry)")].trim()));

            for (String ecNumber : fields[headerMap.get("EC number")].split(";")) {
                entry.addECRef(new UniprotECRef(ecNumber.trim()));
            }

            for (String goTerm : fields[headerMap.get("Gene ontology IDs")].split(";")) {
                entry.addGORef(new UniprotGORef(goTerm.trim()));
            }

            for (String interpro : fields[headerMap.get("Cross-reference (InterPro)")].split(";")) {
                entry.addInterProRef(new UniprotInterProRef(interpro.trim()));
            }

            entry.setTaxonId(Integer.parseInt(fields[headerMap.get("Organism ID")]));

            // Emit entry that's finished and handle it...
            observer.handleEntry(entry);
            line = reader.readLine();
        }

        reader.close();
    }
}
