import sys
import csv
import json
import requests
import argparse


def convert_to_json(rows, fields, index_name, id_field):
    """
    Convert a list of TSV-rows to JSON objects. The fields array should correspond to the columns of the TSV (in the
    same order!).

    :param rows:
    :param fields:
    :return:
    """
    objects = []
    id_field_idx = fields.index(id_field)
    
    for row in rows:
        object = {}
        splitted_row = row.split("\t")
        for (idx, field) in enumerate(fields):
            object[field] = splitted_row[idx]
        action = {"index": {"_index": index_name, "_id": splitted_row[id_field_idx]}}
        objects.append(json.dumps(action))
        objects.append(json.dumps(object))
    return objects

def upload_bulk(objects, opensearch_url):
    """
    Upload the given set of objects to an OpenSearch instance running at the given URL.

    :param objects:
    :param opensearch_url:
    :return:
    """

    payload = '\n'.join(objects) + '\n'

    response = requests.post(
        f"{opensearch_url}/_bulk",
        headers={"Content-Type": "application/x-ndjson"},
        data=payload
    )

    if response.status_code >= 300 or response.json().get("errors"):
        print("❌ Error uploading batch:", file=sys.stderr)
        print(response.text, file=sys.stderr)
        exit(1)


def main():
    parser = argparse.ArgumentParser(description="Upload TSV data to OpenSearch")
    parser.add_argument("--index-name", required=True, type=str, help="The index name to upload data to in OpenSearch")
    parser.add_argument("--fields", required=True, type=str,
                        help="Comma-delimited list of field names for the TSV columns")
    parser.add_argument("--id-field", required=True, type=str,
                        help="The field to use as the document ID in the OpenSearch index")
    parser.add_argument("--batch-size", type=int, default=1000, help="Number of objects in each batch upload")
    parser.add_argument("--opensearch-url", type=str, default="http://localhost:9200",
                        help="URL of the OpenSearch instance")

    args = parser.parse_args()

    index_name = args.index_name
    fields = args.fields.split(",")
    id_field = args.id_field
    batch_size = args.batch_size
    opensearch_url = args.opensearch_url

    lines = []
    for line in sys.stdin:
        lines.append(line.rstrip())

        if len(lines) == batch_size:
            converted_lines = convert_to_json(lines, fields, index_name, id_field)
            upload_bulk(converted_lines, opensearch_url)
            lines = []

    if len(lines) > 0:
        converted_lines = convert_to_json(lines, fields, index_name, id_field)
        upload_bulk(converted_lines, opensearch_url)

if __name__ == "__main__":
    main()
