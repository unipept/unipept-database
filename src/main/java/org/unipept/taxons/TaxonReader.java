package org.unipept.taxons;

import java.util.Set;
import java.util.HashSet;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStreamReader;
import java.io.FileInputStream;
import java.io.IOException;

public class TaxonReader {
    /**
     * Reads a file that contains a one taxon id per line. These id's will be parsed as integers by this script and a
     * set containing all these taxa will be returned.
     * 
     * @param taxonFile
     */
    public Set<Integer> readTaxonList(String taxonFile) throws IOException {
        Set<Integer> output = new HashSet<Integer>();

        BufferedReader buffer = new BufferedReader(
            new InputStreamReader(
                new FileInputStream(taxonFile)
            )
        );

        String line = buffer.readLine();
        while (line != null) {
            output.add(Integer.parseInt(line.strip()));
            line = buffer.readLine();
        }

        return output;
    }
}
