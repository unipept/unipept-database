/**
 * This script looks for which taxa should be looked up in which chunk. The list of taxa that need to be looked up is
 * read from stdin. A list of files, taxa (thus the taxa that need to be looked up in the corresponding file) are
 * provided through stdout.
 *
 * The script requires two command line arguments: the folder in which all Unipept DB chunks are present and a
 * temporary folder that can be used by the script to store temporary files.
 */

const fs = require("fs/promises");
const path = require("path");

const args = process.argv;

if (args.length !== 4) {
	console.error("This script expects exactly two parameters: unipept_db_chunk_folder temporary_folder");
	process.exit(1);
}

(async() => {
    const allTaxa = (await fs.readFile("/dev/stdin")).toString().split("\n").map(l => parseInt(l.trim()));

    // In this hook we should start to link input files with the taxa that need to be looked up in there.
    for (const file of (await fs.readdir(args[2]))) {
        const baseFile = path.basename(file);
        if (baseFile.match(/unipept\..*\.gz/)) {
            const range = baseFile.replace(/unipept\.|\.gz/g, '').split("-");
            const startRange = parseInt(range[0]);
            const endRange = parseInt(range[1]);

            const matchedTaxa = allTaxa.filter(t => startRange <= t && t <= endRange);

            if (matchedTaxa && matchedTaxa.length > 0) {
                await fs.writeFile(path.join(args[3], baseFile + ".pattern"), matchedTaxa.map(t => "\t" + t + "$").join("\n"));

                console.log(path.join(args[3], baseFile + ".pattern"));
                console.log(path.join(args[2], file));
            }
        }
    }
})();

