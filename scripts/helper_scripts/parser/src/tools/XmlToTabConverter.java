package tools;

import org.xml.sax.SAXException;
import storage.TabWriter;
import xml.UniprotHandler;

import javax.xml.parsers.ParserConfigurationException;
import javax.xml.parsers.SAXParser;
import javax.xml.parsers.SAXParserFactory;
import java.io.*;

/**
 * This tool accepts 3 different arguments:
 * peptide_min_length, peptide_max_length, database_type_name
 *
 * The input is read from stdin and the output of this script is written to stdout.
 *
 * This tool's job is to produce a TSV-file with the same contents as the XML-file that's fed into this script.
 */
public class XmlToTabConverter {
    public static void main(String[] args) throws IOException, SAXException, ParserConfigurationException {
        SAXParser parser = SAXParserFactory.newInstance().newSAXParser();

        InputStream uniprotStream = System.in;
        UniprotHandler handler = new UniprotHandler(Integer.parseInt(args[0]), Integer.parseInt(args[1]), args[2]);

        TabWriter writer = new TabWriter(System.out);
        handler.addObserver(writer);

        parser.parse(uniprotStream, handler);

        uniprotStream.close();
        writer.close();
    }
}
