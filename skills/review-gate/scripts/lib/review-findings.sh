# shellcheck shell=bash
# GitHub's author type identifies automatic reviewers for refresh-reviews.
AUTOMATIC_AUTHOR_DEF='def automatic_author: (.__typename // .type // "User") == "Bot";'
