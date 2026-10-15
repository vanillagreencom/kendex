#!/usr/bin/env bash
control_expect 'expired session records no further attempts'
control_replace scripts/lib/common.sh 1 \
    '    if ((now >= $(jq -r '\''.expires_at'\'' <<<"$_LJ_SESSION"))); then' \
    '    if false; then'
