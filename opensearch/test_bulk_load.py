"""Tests for bulk_load.py, against a stand-in for the OpenSearch HTTP session.

Run from the repository root: python3 -m unittest discover -s opensearch
"""

import contextlib
import io
import json
import sys
import unittest
from unittest import mock

import requests

import bulk_load

FIELDS = "accession,taxon"


class Reply:
    def __init__(self, status_code, body):
        self.status_code = status_code
        self.text = json.dumps(body)
        self._body = body

    def json(self):
        return self._body

    @staticmethod
    def ok():
        return Reply(200, {"errors": False, "items": []})

    @staticmethod
    def rejected(*statuses):
        return Reply(200, {"errors": True, "items": [{"index": {"status": status}} for status in statuses]})


class Session:
    """Answers each bulk request with the next reply and keeps what was sent."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.payloads = []
        self.requests = []

    def post(self, url, headers, data, timeout):
        self.payloads.append(data)
        self.requests.append((url, headers, timeout))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


def load(rows, session, *args):
    """Runs main() on the rows and returns its exit status and what it wrote to stderr."""
    argv = ["bulk_load.py", "--index-name", "entries", "--fields", FIELDS, "--id-field", "accession", *args]
    stderr = io.StringIO()
    patches = [
        mock.patch.object(sys, "argv", argv),
        mock.patch.object(sys, "stdin", io.StringIO("".join(rows))),
        mock.patch.object(sys, "stderr", stderr),
        mock.patch.object(bulk_load.requests, "Session", return_value=session),
        mock.patch.object(bulk_load.time, "sleep")
    ]
    with contextlib.ExitStack() as stack:
        for patch in patches:
            stack.enter_context(patch)
        try:
            bulk_load.main()
            status = 0
        except SystemExit as error:
            status = error.code
    return status, stderr.getvalue()


def documents(payload):
    """The (index, id, source) of every document in a bulk payload."""
    lines = payload.strip("\n").split("\n")
    return [
        (json.loads(action)["index"]["_index"], json.loads(action)["index"]["_id"], json.loads(source))
        for action, source in zip(lines[::2], lines[1::2])
    ]


class BulkLoadTest(unittest.TestCase):
    def test_uploads_in_batches_keyed_by_the_id_field(self):
        session = Session(Reply.ok(), Reply.ok())
        status, stderr = load(["P1\t8501\n", "P2\t8502\n", "P3\t7\n"], session, "--batch-size", "2")
        self.assertEqual(status, 0)
        self.assertEqual([documents(payload) for payload in session.payloads], [
            [("entries", "P1", {"accession": "P1", "taxon": "8501"}),
             ("entries", "P2", {"accession": "P2", "taxon": "8502"})],
            [("entries", "P3", {"accession": "P3", "taxon": "7"})],
        ])
        self.assertIn("3 rows indexed", stderr)
        self.assertEqual(session.requests[0], (
            "http://localhost:9200/_bulk", {"Content-Type": "application/x-ndjson"}, bulk_load.REQUEST_TIMEOUT
        ))

    def test_the_id_field_is_not_the_first_column(self):
        session = Session(Reply.ok())
        argv = ["--fields", "taxon,accession", "--opensearch-url", "http://opensearch:9200"]
        status, _ = load(["8501\tP1\n"], session, *argv)
        self.assertEqual(status, 0)
        self.assertEqual(documents(session.payloads[0]), [("entries", "P1", {"taxon": "8501", "accession": "P1"})])
        self.assertEqual(session.requests[0][0], "http://opensearch:9200/_bulk")

    def test_an_empty_last_column_is_kept(self):
        session = Session(Reply.ok())
        status, _ = load(["P1\t\n"], session)
        self.assertEqual(status, 0)
        self.assertEqual(documents(session.payloads[0]), [("entries", "P1", {"accession": "P1", "taxon": ""})])

    def test_skip_passes_over_the_leading_rows(self):
        session = Session(Reply.ok())
        status, _ = load(["P1\t8501\n", "P2\t8502\n"], session, "--skip", "1")
        self.assertEqual(status, 0)
        self.assertEqual([accession for _, accession, _ in documents(session.payloads[0])], ["P2"])

    def test_a_short_row_names_its_line_and_where_to_continue(self):
        session = Session(Reply.ok())
        status, stderr = load(["P1\t8501\n", "P2\t8502\n", "P3\n"], session, "--batch-size", "2")
        self.assertEqual(status, 1)
        self.assertIn("line 3: expected 2 columns, found 1", stderr)
        self.assertIn("Continue with --skip 2", stderr)

    def test_retries_a_busy_cluster(self):
        session = Session(requests.ConnectionError("reset"), Reply(503, {}), Reply.rejected(201, 429), Reply.ok())
        status, _ = load(["P1\t8501\n", "P2\t8502\n"], session)
        self.assertEqual(status, 0)
        self.assertEqual(len(session.payloads), 4)

    def test_it_gives_up_after_the_last_attempt(self):
        session = Session(*[Reply(503, {})] * bulk_load.MAX_ATTEMPTS)
        status, stderr = load(["P1\t8501\n"], session)
        self.assertEqual(status, 1)
        self.assertEqual(len(session.payloads), bulk_load.MAX_ATTEMPTS)
        self.assertIn(f"gave up after {bulk_load.MAX_ATTEMPTS} attempts", stderr)
        self.assertIn("Continue with --skip 0", stderr)

    def test_a_refused_batch_is_not_retried(self):
        session = Session(Reply(400, {}))
        status, stderr = load(["P1\t8501\n"], session)
        self.assertEqual(status, 1)
        self.assertEqual(len(session.payloads), 1)
        self.assertIn("refused the batch with 400", stderr)

    def test_a_rejected_document_is_not_retried(self):
        session = Session(Reply.rejected(201, 400))
        status, stderr = load(["P1\t8501\n", "P2\t8502\n"], session)
        self.assertEqual(status, 1)
        self.assertEqual(len(session.payloads), 1)
        self.assertIn("rejected documents in the batch", stderr)


if __name__ == "__main__":
    unittest.main()
