# Widen the identifier arm to accept lowercase team keys. A leaked fixture id
# shaped like `uuid-1` then passes validation and goes into the batch filter,
# which Linear rejects as a whole — the poisoned cache this guard exists for.
control_expect "the identifier-shaped id 'uuid-1' never reaches the API"
control_replace scripts/commands/sync.sh 1 \
    "    local id_shape_regex='^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[A-Z][A-Z0-9]*-[0-9]+)\$'" \
    "    local id_shape_regex='^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[A-Za-z][A-Za-z0-9]*-[0-9]+)\$'"

# Put the legacy-lock sweep back on a write path, where an incremental sync
# whose delta is empty never reaches it (kendex#799).
control_expect "a sync whose delta is empty still sweeps the legacy per-issue locks"
control_replace scripts/commands/sync.sh 1 \
    '    rm -f "$CACHE_DIR"/comments/*.json.lock || true' \
    '    :'
