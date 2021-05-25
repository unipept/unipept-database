const readline = require('readline');
const fs = require("fs");

const args = process.argv;

if (args.length !== 4) {
    console.log("This script requires: taxons_to_keep output_file");
    console.log("Please provide the complete lineage reference through stdin.")
    process.exit(1);
}

const rl = readline.createInterface({
  input: process.stdin
});

const taxonsToKeep = new Set(args[2].split(",").map(x => parseInt(x)));
const set = new Set();

let i = 0;

rl.on("line", (line) => {
    const splitted = line.split("\t").filter(x => x !== "\\N").map(x => parseInt(x)).filter(x => x >= 0);

    let shouldAdd = false;
    for (const taxon of splitted) {
        shouldAdd = shouldAdd || taxonsToKeep.has(taxon);
    }

    if (shouldAdd) {
        for (const taxon of splitted) {
            set.add(taxon);
        }
    }
    
    i++;

    if (i % 100000 === 0) {
        console.log("Checked " + i + " lineages...");
    }
});

rl.on("close", () => {
    for (const taxon of taxonsToKeep) {
        set.add(taxon);
    }

    // Write to file
    const writer = fs.createWriteStream(args[3]);

    for (const item of set) {
        writer.write(item + "\n");
    }
});

