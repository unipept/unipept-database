#!/usr/bin/env bash
#
# Stands in for lz4 so the suite needs no compression tool. STUB_LZ4_MODE picks the behaviour:
#
#   late   read all of stdin, then fail — a failure the producer never sees
#   early  fail before reading anything
#   slow   succeed, but finish after the producer has exited

case "${STUB_LZ4_MODE:-}" in
    late)
        cat > /dev/null
        exit 1
        ;;
    early)
        exit 1
        ;;
    slow)
        sleep 1
        exec cat
        ;;
    *)
        echo "stub-lz4: STUB_LZ4_MODE is '${STUB_LZ4_MODE:-unset}'" >&2
        exit 2
        ;;
esac
