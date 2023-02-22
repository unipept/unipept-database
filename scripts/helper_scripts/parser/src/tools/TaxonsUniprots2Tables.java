package tools;

import java.io.IOException;

import com.beust.jcommander.Parameter;
import com.beust.jcommander.JCommander;

import storage.TableWriter;
import tsv.UniprotTabParser;

public class TaxonsUniprots2Tables {

    @Parameter(names="--peptide-min",     description="Minimum peptide length")               public int peptideMin;
    @Parameter(names="--peptide-max",     description="Maximum peptide length")               public int peptideMax;
    @Parameter(names="--taxons",          description="Taxons TSV input file")                public String taxonsFile;
    @Parameter(names="--peptides",        description="Peptides TSV output file")             public String peptidesFile;
    @Parameter(names="--uniprot-entries", description="Uniprot entries TSV output file")      public String uniprotEntriesFile;
    @Parameter(names="--ec",              description="EC references TSV output file")        public String ecCrossReferencesFile;
    @Parameter(names="--go",              description="GO references TSV output file")        public String goCrossReferencesFile;
    @Parameter(names="--interpro",        description="InterPro references TSV output file")  public String interProCrossReferencesFile;
    @Parameter(names="--kegg",            description="KEGG references TSV output file")      public String keggCrossReferencesFile;
    @Parameter(names="--verbose",         description="Enable verbose mode")                  public boolean verboseMode;

    /**
     * Parse the UniProt TSV-file into TSV tables.
     *
     * The first parameter is a taxon file, as written by NamesNodes2Taxons. The next 5 parameters are the output files,
     * all in TSV format. In order, they are: the peptides, the uniprot entries, the EC cross references, the GO cross
     * references and the InterPro cross references.
     *
     * This program reads input from stdin and writes output to the files indicated by the parameters given above.
     */
    public static void main(String[] args) throws IOException {
        TaxonsUniprots2Tables main = new TaxonsUniprots2Tables();
        new JCommander(main, args);

        if (main.verboseMode) {
            System.err.println("INFO: TaxonsUniprots2Tables - Verbose mode enabled.");
        }

        TableWriter writer = new TableWriter(main);

        UniprotTabParser parser = new UniprotTabParser();
        parser.parse(main.peptideMin, main.peptideMax, System.in, writer, main.verboseMode);

        writer.close();
    }

}

