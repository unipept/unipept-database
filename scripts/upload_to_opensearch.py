import sys
import json
import time
import argparse

import requests

# A load runs for hours, so one slow or failed request must not end it. Only a transport error,
# a 5xx and a 429 are retried; a 4xx and a document OpenSearch rejects are the payload itself,
# which another attempt cannot change.
REQUEST_TIMEOUT = 120
MAX_ATTEMPTS = 5
BACKOFF_SECONDS = 2


def convert_to_json(rows, fields, index_name, id_field, first_line):
    """
    Convert a list of TSV-rows to JSON objects. The fields array should correspond to the columns of the TSV (in the
    same order!).

    :param rows:
    :param fields:
    :param index_name:
    :param id_field:
    :param first_line: line number of rows[0] in the input, used to report a row of the wrong width
    :return:
    """
    objects = []
    id_field_idx = fields.index(id_field)

    for offset, row in enumerate(rows):
        values = row.split("\t")

        # A row of the wrong width means the table this reads has changed shape. Reported here,
        # naming the line, rather than left to raise an IndexError further down.
        if len(values) != len(fields):
            raise ValueError(
                f"line {first_line + offset}: expected {len(fields)} columns, found {len(values)}"
            )

        action = {"index": {"_index": index_name, "_id": values[id_field_idx]}}
        objects.append(json.dumps(action))
        objects.append(json.dumps(dict(zip(fields, values))))
    return objects


def upload_bulk(objects, opensearch_url):
    """
    Upload the given set of objects to an OpenSearch instance running at the given URL.

    :param objects:
    :param opensearch_url:
    :return:
    """
    payload = '\n'.join(objects) + '\n'
    last_error = None

    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            response = requests.post(
                f"{opensearch_url}/_bulk",
                headers={"Content-Type": "application/x-ndjson"},
                data=payload,
                timeout=REQUEST_TIMEOUT
            )
        except requests.RequestException as error:
            last_error = f"the request failed: {error}"
        else:
            if response.status_code == 429 or response.status_code >= 500:
                last_error = f"OpenSearch answered {response.status_code}: {response.text}"
            elif response.status_code >= 300:
                raise RuntimeError(f"OpenSearch refused the batch with {response.status_code}: {response.text}")
            elif response.json().get("errors"):
                raise RuntimeError(f"OpenSearch rejected documents in the batch: {response.text}")
            else:
                return

        if attempt < MAX_ATTEMPTS:
            time.sleep(BACKOFF_SECONDS * attempt)

    raise RuntimeError(f"gave up after {MAX_ATTEMPTS} attempts: {last_error}")


def main():
    parser = argparse.ArgumentParser(description="Upload TSV data to OpenSearch")
    parser.add_argument("--index-name", required=True, type=str, help="The index name to upload data to in OpenSearch")
    parser.add_argument("--fields", required=True, type=str,
                        help="Comma-delimited list of field names for the TSV columns")
    parser.add_argument("--id-field", required=True, type=str,
                        help="The field to use as the document ID in the OpenSearch index")
    parser.add_argument("--batch-size", type=int, default=2500, help="Number of objects in each batch upload")
    parser.add_argument("--opensearch-url", type=str, default="http://localhost:9200",
                        help="URL of the OpenSearch instance")
    parser.add_argument("--skip", type=int, default=0,
                        help="Number of leading rows to pass over, to continue an interrupted upload")

    args = parser.parse_args()

    index_name = args.index_name
    fields = args.fields.split(",")
    id_field = args.id_field
    batch_size = args.batch_size
    opensearch_url = args.opensearch_url

    uploaded = args.skip
    lines = []
    batch_starts_at = args.skip + 1

    try:
        for line_number, line in enumerate(sys.stdin, start=1):
            if line_number <= args.skip:
                continue

            # Only the newline: the last column is allowed to be empty, and stripping every
            # trailing whitespace character takes the tab in front of it with it.
            lines.append(line.rstrip("\n"))

            if len(lines) == batch_size:
                upload_bulk(convert_to_json(lines, fields, index_name, id_field, batch_starts_at), opensearch_url)
                uploaded += len(lines)
                batch_starts_at = uploaded + 1
                lines = []

        if len(lines) > 0:
            upload_bulk(convert_to_json(lines, fields, index_name, id_field, batch_starts_at), opensearch_url)
            uploaded += len(lines)
    except (ValueError, RuntimeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        print(f"{uploaded} rows are indexed. Continue with --skip {uploaded}.", file=sys.stderr)
        sys.exit(1)

    print(f"{uploaded - args.skip} rows indexed.", file=sys.stderr)


if __name__ == "__main__":
    main()
