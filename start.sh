#!/bin/sh
set -e
python -m ide_storage.mcp_standalone &
exec python -m ide_storage.main
