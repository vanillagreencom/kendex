# Restore the operand order BSD chmod reads as a missing file named `--`: the
# mode is set, chmod exits 1, and the store reports the hold as unavailable.
control_expect 'a future hold is saved under BSD chmod'
control_replace scripts/lib/common.sh 1 \
    '    chmod -- 700 "$dir" || { linear_quota_unavailable "private:$dir"; return 1; }' \
    '    chmod 700 -- "$dir" || { linear_quota_unavailable "private:$dir"; return 1; }'
