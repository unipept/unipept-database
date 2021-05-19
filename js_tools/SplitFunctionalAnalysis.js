const readline = require('readline');
const fs = require('fs');

const exec = require('child_process').exec;

const start = new Date().getTime();
const args = process.argv;

if (args.length !== 5) {
    console.log("Please provide 3 parameters: input, output and maximum level of parallelisation (n).");
    process.exit(1);
}

const inputFile = args[2];
const outputFile = args[3];
const parallelism = args[4];

exec("wc -l " + inputFile, function (error, results) {
    const lines = parseInt(results.split(/\s+/)[0]);
    const splits = [];
    const splitSize = Math.floor(lines / parallelism);

    for (let i = 1; i < parallelism; i++) {
        splits.push(splitSize * i);
    }

    const readInterface = readline.createInterface({
        input: fs.createReadStream(inputFile)
    });

    let currentPart = 1;

    let writer = fs.createWriteStream(outputFile + `-${currentPart}.tmp`);

    let split = splits[0];
    let linesRead = 0;
    let previousPept = "";

    readInterface.on('line', (line) => {
        ++linesRead;
        if (linesRead === split - 1) {
            previousPept = line.split("\t")[0];
        } else if (linesRead >= split && line.split("\t")[0] !== previousPept) {
            // Switch to the next split point
            writer.close();
            split = splits[currentPart];
            currentPart += 1;
            writer = fs.createWriteStream(outputFile + `-${currentPart}.tmp`);
        }
        writer.write(`${line}\n`);
    });

    readInterface.on('close', () => {
        writer.close();

        const end = new Date().getTime();
        console.log("Took " + (end - start) / 1000 + "s");
    });    
});
