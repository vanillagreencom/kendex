# Drop syncedWith from the live `issues get` query, so the read that names a
# synced issue's GitHub issue asks Linear for nothing and prints no github_sync.
control_expect "a synced mirror names its GitHub issue"
control_replace scripts/commands/issues.sh 1 \
    '                syncedWith { metadata { ... on ExternalEntityInfoGithubMetadata { owner repo number } } }' \
    ''
