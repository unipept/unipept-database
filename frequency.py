import sys
from collections import defaultdict

order = [
	["subspecies", "strain", "varietas", "forma"],
	["species"],
	["genus", "subgenus", "species group", "species subgroup"],
	["family", "subfamily", "tribe", "subtribe"],
	["order", "suborder", "infraorder", "superfamily"],
	["class", "subclass", "superorder"],
	["phylum", "subphylum", "superclass"],
	["superkingdom", "kingdom", "subkingdom", "superphylum"],
	["no rank"]
]

counts = defaultdict(int)
count = 0
for line in sys.stdin:
	counts[line.strip()] += 1
	count += 1

	if count > 1000:
		count = 0
		grouped = { group[0]: sum(counts[rank] for rank in group) for group in order }
		maximum = max(value for key, value in grouped.items())
		with open(sys.argv[1], 'w') as f:
			for group in order:
				#print(f'{group[0] + ":":15} {"-" * (100 * grouped[group[0]] // maximum)} ({grouped[group[0]]:,})', file=f)
				print('{0:15} {1} ({2:,})'.format(
					group[0] + ":",
					"-" * (100 * grouped[group[0]] // maximum),
					grouped[group[0]]
				), file=f)
