# Tick every open box whatever the caller named: a partly met item closes
# with its unmet boxes checked.
control_expect "the unnamed branch box is identified"
control_replace scripts/lib/issue-validation.sh 1 \
    '                | ($open and $selected) as $tick' \
    '                | ($open) as $tick'
