# Credential selection: a configured app pair loses to the personal key, so
# the wrong credential reaches the wire.
control_expect 'mint: request succeeds'
control_replace scripts/lib/auth.sh 1 \
    '    LINEAR_AUTH_KIND="app"' \
    '    LINEAR_AUTH_KIND="api-key"'

# The token store, an instrument selection cannot redden: the token file is
# written readable by other users.
control_expect 'token file: private'
control_replace scripts/lib/auth.sh 1 \
    '    umask 077' \
    '    umask 022'
