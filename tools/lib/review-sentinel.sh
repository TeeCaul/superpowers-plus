#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tools/lib/review-sentinel.sh
# PURPOSE: Read-only validation of the three review sentinels
#          (.code-review-cleared, .phr-cleared, .llm-skill-review-cleared),
#          matching what each owning pre-push gate accepts.
# SOURCED BY: tools/push-readiness.sh, tools/review-preflight.py (via bash -c)
# REQUIRES: tools/lib/code-review-sentinel.sh already sourced
#           (parse_code_review_sentinel).
# -----------------------------------------------------------------------------
# shellcheck disable=SC2034  # SENTINEL_* are outputs read by sourcing callers

# Parse and validate a review sentinel exactly as its owning pre-push gate does.
# Outputs are returned through SENTINEL_SHA, SENTINEL_VERDICT and
# SENTINEL_ERROR so the caller can keep report formatting in one place.
validate_review_sentinel() {
  local sentinel="$1" base line line_count field_count
  local ver sha verdict ts f5 f6 f7
  base="${sentinel##*/}"
  line_count="$(awk 'NF{c++} END{print c+0}' "$sentinel" 2>/dev/null || echo 0)"
  line="$(head -n1 "$sentinel" 2>/dev/null || true)"
  field_count="$(awk -F'|' '{print NF; exit}' <<< "$line")"
  IFS='|' read -r ver sha verdict ts f5 f6 f7 <<< "$line"

  SENTINEL_SHA="$sha"
  SENTINEL_VERDICT="$verdict"
  SENTINEL_ERROR=""

  if [[ "$line_count" -gt 1 ]]; then
    SENTINEL_ERROR="malformed (${line_count} non-blank lines; must be exactly 1)"
    return
  fi

  case "$base" in
    .code-review-cleared)
      parse_code_review_sentinel "$sentinel" || true
      SENTINEL_SHA="$CODE_REVIEW_SENTINEL_SHA"
      SENTINEL_VERDICT="$CODE_REVIEW_SENTINEL_VERDICT"
      SENTINEL_ERROR="$CODE_REVIEW_SENTINEL_ERROR"
      ;;
    .phr-cleared)
      if [[ "$ver" != "v1" || "$field_count" -ne 5 || -z "$sha" || -z "$verdict" || -z "$ts" || -z "$f5" ]]; then
        SENTINEL_ERROR="format unrecognized (expected v1|SHA|VERDICT|TIMESTAMP|min-score=N)"
      elif [[ ! "$f5" =~ ^min-score=[0-9]+(\.[0-9]+)?$ ]]; then
        SENTINEL_ERROR="format unrecognized (malformed min-score field '$f5')"
      fi
      ;;
    .llm-skill-review-cleared)
      if [[ "$ver" != "v2" || "$field_count" -ne 7 || -z "$sha" || -z "$verdict" || -z "$ts" || -z "$f5" || -z "$f6" || -z "$f7" ]]; then
        SENTINEL_ERROR="format unrecognized (expected v2|SHA|VERDICT|TIMESTAMP|mean=N|unresolved_s0_s1=0|evidence_replay=ok)"
      elif [[ ! "$f5" =~ ^mean=[0-9]+(\.[0-9]+)?$ ]]; then
        SENTINEL_ERROR="format unrecognized (malformed mean field '$f5')"
      elif [[ "$f6" != "unresolved_s0_s1=0" ]]; then
        SENTINEL_ERROR="unresolved_s0_s1 is not 0 (got '$f6')"
      elif [[ "$f7" != "evidence_replay=ok" && "$f7" != "evidence_replay=bypassed" ]]; then
        SENTINEL_ERROR="format unrecognized (malformed evidence_replay field '$f7')"
      elif [[ "$f7" == "evidence_replay=bypassed" && "$verdict" != "PASS" ]]; then
        SENTINEL_ERROR="evidence_replay=bypassed requires verdict PASS"
      fi
      ;;
    *)
      SENTINEL_ERROR="unknown sentinel type '$base'"
      ;;
  esac
}

# Verdicts that clear each sentinel's pre-push gate, space-separated. Each gate
# accepts a DIFFERENT set; unknown sentinels fail closed to PASS only.
#   .code-review-cleared      PASS, PASS_WITH_NITS   pre-push-code-review-gate.sh
#   .llm-skill-review-cleared PASS, PASS_WITH_RISKS  pre-push-llm-skill-review-gate.sh
#   .phr-cleared              PASS only              pre-push-phr-gate.sh
review_sentinel_accepted_verdicts() {
  case "${1##*/}" in
    .code-review-cleared)      echo "PASS PASS_WITH_NITS" ;;
    .llm-skill-review-cleared) echo "PASS PASS_WITH_RISKS" ;;
    *)                         echo "PASS" ;;
  esac
}
