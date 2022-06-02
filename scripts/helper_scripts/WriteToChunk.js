const readline = require("readline");
const fs = require("fs");
const path = require("path");

const outputDir = process.argv[2];

const rl = readline.createInterface({
    input: process.stdin
});

const taxaBounds = [
    0, 550, 1352, 3047, 5580, 8663, 11676, 32473, 40214, 52774, 66656, 86630, 116960, 162147, 210225, 267979, 334819,
    408172, 470868, 570509, 673318, 881260, 1046115, 1136135, 1227077, 1300307, 1410620, 1519492, 1650438, 1756149,
    1820614, 1871070, 1898104, 1922217, 1978231, 2024617, 2026757, 2035430, 2070414, 2202732, 2382165, 2527964, 2601669,
    2706029, 10000000
];

const fileObjects = [...Object.keys(taxaBounds)].slice(0, -1).map(idx => Number.parseInt(idx)).map(
    idx => fs.createWriteStream(path.join(outputDir, `unipept.${taxaBounds[idx]}-${taxaBounds[idx + 1]}.chunk`))
);

let headerSkipped = false;

rl.on("line", (line) => {
    if (!headerSkipped) {
        headerSkipped = true;
        const writeStream = fs.createWriteStream(path.join(outputDir, 'db.header'));
        writeStream.write(line + "\n");
        writeStream.close();
        return;
    }

    const taxonId = Number.parseInt(line.split("\t")[8].trim());

    let idx = 0;
    while (taxonId > taxaBounds[idx]) {
        idx++;
    }

    fileObjects[idx - 1].write(line + "\n");
});

rl.on("close", () => fileObjects.map(o => o.close()));
