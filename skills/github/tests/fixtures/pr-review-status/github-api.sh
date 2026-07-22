#!/usr/bin/env bash

bot_review_status() {
    local reviewer="$2"

    printf '%s\n' "$reviewer" >> "$BOT_REVIEW_STATUS_CALL_LOG"
    case "$reviewer" in
        pending-bot-extra)
            printf '{"status":"pending"}\n'
            ;;
        approved-live)
            printf '{"status":"approved"}\n'
            ;;
        unknown-bot)
            printf '{"status":"unknown"}\n'
            ;;
        *)
            printf '{"status":"changes"}\n'
            ;;
    esac
}
