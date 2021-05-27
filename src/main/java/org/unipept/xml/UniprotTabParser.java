package org.unipept.xml;

import java.io.BufferedReader;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.HashMap;
import java.util.Map;
import java.util.stream.Stream;

public class UniprotTabParser {
    public void parse(
        int peptideMinLength, 
        int peptideMaxLength, 
        String tabFile, 
        UniprotObserver observer
    ) throws IOException {
        BufferedReader reader = new BufferedReader(new InputStreamReader(new FileInputStream(tabFile)));

        String line = reader.readLine().strip();
        String[] header = Stream.of(line.split("\t")).map(item -> item.strip()).toArray(String[]::new);

        Map<String, Integer> headerMap = new HashMap<String, Integer>();
        for (int i = 0; i < header.length; i++) {
            headerMap.put(header[i], i);
        }

        line = reader.readLine();

        while (line != null) {
            String[] fields = line.strip().split("\t");

            // We need to emit one new UniprotEntry per line in the input
            UniprotEntry entry = new UniprotEntry(fields[headerMap.get("Status")].strip(), peptideMinLength, peptideMaxLength);

            // Now convert all fields into the correct Uniprot entry properties
            entry.setUniprotAccessionNumber(fields[headerMap.get("Entry")]);
            entry.setSequence(fields[headerMap.get("Sequence")].strip());

            entry.setRecommendedName(fields[headerMap.get("Protein names")].strip());
            // Todo, does not always need to be set?
            // entry.setSubmittedName("name");
            
            entry.setVersion(Integer.parseInt(fields[headerMap.get("Version (entry)")].strip()));
            
            for (String ecNumber : fields[headerMap.get("EC number")].split(";")) {
                entry.addECRef(new UniprotECRef(ecNumber.strip()));
            }

            for (String goTerm : fields[headerMap.get("Gene ontology IDs")].split(";")) {
                entry.addGORef(new UniprotGORef(goTerm.strip()));
            }

            for (String interpro : fields[headerMap.get("Cross-reference (InterPro)")].split(";")) {
                entry.addInterProRef(new UniprotInterProRef(interpro.strip()));
            }

            entry.setTaxonId(Integer.parseInt(fields[headerMap.get("Organism ID")]));

            // Emit entry that's finished and handle it...
            observer.handleEntry(entry);
            line = reader.readLine();
        }

        reader.close();
    }
}
