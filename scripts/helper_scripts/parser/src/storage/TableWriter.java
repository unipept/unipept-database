package storage;

import taxons.TaxonList;
import tools.TaxonsUniprots2Tables;
import xml.*;

import java.util.Set;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.ArrayList;
import java.util.HashMap;
import java.io.IOException;
import java.io.File;
import java.sql.Timestamp;


/**
 * Intermediate class to add PeptideData to the database
 *
 * @author Bart Mesuere
 * @author Felix Van der Jeugt
 *
 */
public class TableWriter implements UniprotObserver {

    public static final String[] ranks = new String[]{"taxon_id", "superkingdom", "kingdom", "subkingdom", "superphylum", "phylum", "subphylum","superclass", "class", "subclass", "superorder", "order", "suborder", "infraorder", "superfamily", "family", "subfamily", "tribe", "subtribe", "genus", "subgenus", "species_group", "species_subgroup", "species", "subspecies", "strain", "varietas", "forma"};
    private static final Map<String, Integer> rankIndices = new HashMap<>();

    static {
        for(int i = 0; i < ranks.length; i++) {
            rankIndices.put(ranks[i], i);
        }
    }

    private TaxonList taxonList;
    private Set<Integer> wrongTaxonIds;

    // csv files
    private CSV.IndexedWriter peptides;
    private CSV.IndexedWriter uniprotEntries;
    private CSV.IndexedWriter goCrossReferences;
    private CSV.IndexedWriter ecCrossReferences;
    private CSV.IndexedWriter interProCrossReferences;
    private CSV.IndexedWriter keggCrossReferences;

    /**
     * Creates a new data object
     */
    public TableWriter(TaxonsUniprots2Tables args) {
        wrongTaxonIds = new HashSet<Integer>();

        /* Opening CSV files for writing. */
        try {
            taxonList = TaxonList.loadFromFile(args.taxonsFile);
            peptides = new CSV.IndexedWriter(args.peptidesFile);
            uniprotEntries = new CSV.IndexedWriter(args.uniprotEntriesFile);
            ecCrossReferences = new CSV.IndexedWriter(args.ecCrossReferencesFile);
            goCrossReferences = new CSV.IndexedWriter(args.goCrossReferencesFile);
            interProCrossReferences = new CSV.IndexedWriter(args.interProCrossReferencesFile);
            keggCrossReferences = new CSV.IndexedWriter(args.keggCrossReferencesFile);
        } catch(IOException e) {
            System.err.println(new Timestamp(System.currentTimeMillis())
                    + " Error creating tsv files");
            e.printStackTrace();
            System.exit(1);
        }

    }

    /**
     * Stores a complete UniprotEntry in the database
     *
     * @param entry
     *            the UniprotEntry to store
     */
    public void store(UniprotEntry entry) {
        long uniprotEntryId = addUniprotEntry(entry.getUniprotAccessionNumber(), entry.getVersion(),
                entry.getTaxonId(), entry.getType(), entry.getName(), entry.getSequence());
        if (uniprotEntryId != -1) { // failed to add entry

            // todo make cleaner
            String faSummary = Stream.of(
                    entry.getGOReferences().stream().map(UniprotGORef::getId),
                    entry.getECReferences().stream().map(x->"EC:"+x.getId()),
                    entry.getInterProReferences().stream().map(x->"IPR:"+x.getId()),
                    entry.getKeggReferences().stream().map(UniprotKeggRef::getId)
            ).flatMap(i -> i).collect(Collectors.joining(";"));

            for(String sequence : entry.digest()) {
                addData(sequence.replace('I', 'L'), uniprotEntryId, sequence, faSummary);
            }
            for (UniprotGORef ref : entry.getGOReferences())
                addGORef(ref, uniprotEntryId);
            for (UniprotECRef ref : entry.getECReferences())
                addECRef(ref, uniprotEntryId);
            for (UniprotInterProRef ref : entry.getInterProReferences())
                addInterProRef(ref, uniprotEntryId);
            for (UniprotKeggRef ref: entry.getKeggReferences())
                addKeggRef(ref, uniprotEntryId);
        }
    }

    /**
     *
     * Inserts the entry info of a uniprot entry into the database and returns
     * the generated id.
     *
     * @param uniprotAccessionNumber
     *            The accession number of the entry
     * @param version
     *            The version of the entry
     * @param taxonId
     *            The taxonId of the organism of the entry
     * @param type
     *            The type of the entry. Can be swissprot or trembl
     * @param sequence
     *            The full sequence of the peptide.
     * @return The database ID of the uniprot entry.
     */
    public long addUniprotEntry(
            String uniprotAccessionNumber,
            int version,
            int taxonId,
            String type,
            String name,
            String sequence
    ) {
        if(0 <= taxonId && taxonId < taxonList.size() && taxonList.get(taxonId) != null) {
            try {
                uniprotEntries.write(
                        uniprotAccessionNumber,
                        Integer.toString(version),
                        Integer.toString(taxonId),
                        type,
                        name,
                        sequence);
                return uniprotEntries.index();
            } catch(IOException e) {
                System.err.println(new Timestamp(System.currentTimeMillis())
                        + " Error writing to CSV.");
                e.printStackTrace();
            }
        } else {
            if (!wrongTaxonIds.contains(taxonId)) {
                wrongTaxonIds.add(taxonId);
                System.err.println(new Timestamp(System.currentTimeMillis()) + " " + taxonId
                        + " added to the list of " + wrongTaxonIds.size() + " invalid taxonIds.");
            }
        }
        return -1;
    }

    /**
     * Adds peptide data to the database
     *
     * @param unifiedSequence
     *            The sequence of the peptide with AA's I and L the
     *            same.
     * @param uniprotEntryId
     *            The id of the uniprot entry from which the peptide data was
     *            retrieved.
     * @param originalSequence
     *            The original sequence of the peptide.
     * @param functionalAnnotations
     *            A semicolon separated list of allocated functional analysis terms
     */
    public void addData(String unifiedSequence, long uniprotEntryId, String originalSequence, String functionalAnnotations) {
        try {
            peptides.write(
                    unifiedSequence,
                    originalSequence,
                    Long.toString(uniprotEntryId),
                    functionalAnnotations
                    );
        } catch(IOException e) {
            System.err.println(new Timestamp(System.currentTimeMillis())
                    + " Error adding this peptide to the database: " + unifiedSequence);
            e.printStackTrace();
        }
    }


    /**
     * Adds a uniprot entry GO reference to the database
     *
     * @param ref
     *            The uniprot GO reference to add
     * @param uniprotEntryId
     *            The uniprotEntry of the cross reference
     */
    public void addGORef(UniprotGORef ref, long uniprotEntryId) {
        try {
            goCrossReferences.write(Long.toString(uniprotEntryId), ref.getId());
        } catch (IOException e) {
            System.err.println(new Timestamp(System.currentTimeMillis())
                    + " Error adding this GO reference to the database.");
            e.printStackTrace();
        }

    }

    /**
     * Adds a uniprot entry EC reference to the database
     *
     * @param ref
     *            The uniprot EC reference to add
     * @param uniprotEntryId
     *            The uniprotEntry of the cross reference
     */
    public void addECRef(UniprotECRef ref, long uniprotEntryId) {
        try {
            ecCrossReferences.write(Long.toString(uniprotEntryId), ref.getId());
        } catch (IOException e) {
            System.err.println(new Timestamp(System.currentTimeMillis())
                    + " Error adding this EC reference to the database.");
            e.printStackTrace();
        }

    }

    /**
     * Adds a uniprot entry InterPro reference to the database
     *
     * @param ref
     *            The uniprot InterPro reference to add
     * @param uniprotEntryId
     *            The uniprotEntry of the cross reference
     */
    public void addInterProRef(UniprotInterProRef ref, long uniprotEntryId) {
        try {
            interProCrossReferences.write(Long.toString(uniprotEntryId), ref.getId());
        } catch (IOException e) {
            System.err.println(new Timestamp(System.currentTimeMillis())
                    + " Error adding this InterPro reference to the database.");
            e.printStackTrace();
        }
    }

    public void addKeggRef(UniprotKeggRef ref, long uniprotEntryId) {
        try {
            keggCrossReferences.write(Long.toString(uniprotEntryId), ref.getId());
        } catch (IOException e) {
            System.err.println(new Timestamp(System.currentTimeMillis())
                    + " Error adding this KEGG reference to the database.");
            e.printStackTrace();
        }
    }

    @Override
    public void handleEntry(UniprotEntry entry) {
        store(entry);
    }

    @Override
    public void close() {
        try {
            uniprotEntries.close();
            peptides.close();
            goCrossReferences.close();
            ecCrossReferences.close();
            interProCrossReferences.close();
            keggCrossReferences.close();
        } catch(IOException e) {
            System.err.println(new Timestamp(System.currentTimeMillis())
                    + " Something closing the csv files.");
            e.printStackTrace();
        }
    }

}
