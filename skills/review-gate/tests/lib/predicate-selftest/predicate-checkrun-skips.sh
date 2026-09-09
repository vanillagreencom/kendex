# shellcheck shell=bash
# A successful check must attest analysis. The empty list disables this filter.
while IFS='|' read -r name patterns summary want; do
  reset
  CFG_CONTEXTS=mech-ctx; CFG_SKIPS="$patterns"
  checkrun mech-ctx success "$summary"
  run "$name" "$want"
done <<'CASES'
rate-limited live shape|rate limited|Review rate limited. 0 files reviewed.|awaiting
clean analysis|rate limited|Reviewed 12 files, 0 findings|approved
empty list disables filter||Review rate limited. 0 files reviewed.|approved
case-insensitive skip|rate limited|Review RATE LIMITED|awaiting
CASES
