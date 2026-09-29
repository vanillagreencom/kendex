#!/usr/bin/env bash
# pane_asks_person PANE: exit 0 when the lane in PANE waits on the person,
# 1 when it does not, 2 when the pane cannot be read. The lane judge calls it
# before it wakes a lane.
pane_asks_person() { # PANE
  local text
  text="$(tmux capture-pane -p -t "$1" -S -40)" || return 2
  case "$text" in
    *"Do you want to proceed"* | *"Allow this command"* | *"(y/n)"* | \
      *"Press Enter to continue"* | *"waiting for your input"*)
      return 0 ;;
  esac
  return 1
}
