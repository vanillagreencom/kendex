# Each mutation changes a disposable skill copy and names its assertion.
# A removed sync reports its replacement and still exits as if it ran.
control_expect 'sync: exits 1'
control_replace scripts/linear.sh 1 \
    '        echo "linear: removed=sync replacement=none: every read goes to the live API, so drop the sync step" >&2' \
    '        echo "linear: removed=sync replacement=none: every read goes to the live API, so drop the sync step" >&2; exit 0'
# A cache read stops naming the live command it maps to.
control_expect 'cache issues get: names the live command'
control_replace scripts/linear.sh 1 \
    '            echo "linear: removed=cache replacement=linear.sh ${cache_args[*]}" >&2' \
    '            echo "linear: removed=cache replacement=linear.sh <resource> <action>" >&2'
# A whole-set store list maps to a live read that stops at 75 rows.
control_expect 'cache labels list: names the live command'
control_replace scripts/linear.sh 1 \
    '                projects | labels | initiatives) [[ "$cache_bounded" == true ]] || cache_args+=(--max) ;;' \
    '                projects | labels | initiatives) ;;'
# A store cycle type is passed on under a name the live list has no filter for.
control_expect 'cache cycles list --type past: names the live command'
control_replace scripts/linear.sh 1 \
    '                            if [[ "${cache_args[i]}" == past ]]; then cache_args[i]=previous; else cache_args[i]=next; fi' \
    '                            :'
