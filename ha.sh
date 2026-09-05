#!/usr/bin/env bash
# Home Assistant helper for the fox10.shutters Omarchy plugin.
#
# The long-lived token lives only in the 0600 settings file and is handed to
# curl over a heredoc (--config -), so it never appears in argv or `ps`.
#
# Every subcommand prints a single JSON object on stdout:
#   {"ok":true,"code":200,"data":<payload>}
#   {"ok":false,"code":<http|0>,"error":"<message>"}

set -uo pipefail

CONF="${SHUTTERS_CONF:-$HOME/.local/state/omarchy/settings/shutters.json}"

die() {
  jq -nc --arg e "$1" --argjson c "${2:-0}" '{ok:false,code:$c,error:$e}'
  exit 0
}

json_string() { jq -Rn --arg s "$1" '$s'; }

ensure_deps() {
  command -v jq >/dev/null 2>&1 || { printf '{"ok":false,"code":0,"error":"jq is not installed"}'; exit 0; }
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
}

read_conf() {
  [[ -f "$CONF" ]] || return 0
  jq -r "$1 // empty" "$CONF" 2>/dev/null
}

load_config() {
  url="$(read_conf .url)"
  token="$(read_conf .token)"
  url="${url%/}"
  [[ -n "$url" ]] || die "No Home Assistant URL configured"
  [[ "$url" == http://* || "$url" == https://* ]] || url="https://$url"
  [[ -n "$token" ]] || die "No API token configured"
}

# curl_ha <method> <path> [json-body]
# Sets: HTTP_CODE, BODY
curl_ha() {
  local method="$1" path="$2" body="${3:-}"
  local tmp curl_err args
  tmp="$(mktemp)" || die "mktemp failed"
  curl_err="$(mktemp)" || { rm -f "$tmp"; die "mktemp failed"; }

  args=(--silent --show-error --location --max-time 12
        --output "$tmp" --write-out '%{http_code}'
        --request "$method" "$url$path")
  if [[ -n "$body" ]]; then
    args+=(--header 'Content-Type: application/json' --data-binary "$body")
  fi

  # Token goes in via stdin config; escape backslashes and quotes for curl's
  # config-file quoting rules.
  local escaped="${token//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"

  HTTP_CODE="$(curl "${args[@]}" --config - 2>"$curl_err" <<EOF
header = "Authorization: Bearer $escaped"
EOF
)"
  local rc=$?
  BODY="$(cat "$tmp")"
  CURL_ERR="$(tr -d '\r' <"$curl_err" | head -n 1 | head -c 200)"
  rm -f "$tmp" "$curl_err"

  # curl reports 000 when it never got an HTTP response at all.
  HTTP_CODE="$((10#${HTTP_CODE:-0}))"
  if [[ $rc -ne 0 || "$HTTP_CODE" == "0" ]]; then
    return 1
  fi
  return 0
}

http_error_message() {
  case "$1" in
    401|403) printf 'Invalid token (%s)' "$1" ;;
    404) printf 'Endpoint not found (404)' ;;
    0)
      local raw="${CURL_ERR#curl: }"
      raw="${raw#(*) }"
      case "$raw" in
        *SSL*|*certificate*|*TLS*) printf 'TLS error: %s' "$raw" ;;
        "") printf 'Home Assistant unreachable' ;;
        *) printf 'Unreachable: %s' "$raw" ;;
      esac
      ;;
    *) printf 'HTTP %s' "$1" ;;
  esac
}

emit_or_fail() {
  # $1 = jq filter applied to the response body on success
  if [[ "$HTTP_CODE" == "200" ]]; then
    if printf '%s' "$BODY" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$BODY" | jq -c "${1:-.} | {ok:true,code:200,data:.}"
      return 0
    fi
    die "Invalid response from Home Assistant" 200
  fi
  jq -nc --arg e "$(http_error_message "$HTTP_CODE")" --argjson c "${HTTP_CODE:-0}" \
    '{ok:false,code:$c,error:$e}'
}

cmd_states() {
  load_config
  curl_ha GET /api/states
  emit_or_fail '[.[] | select(.entity_id | startswith("cover.")) | {
      entity_id,
      state,
      name: (.attributes.friendly_name // .entity_id),
      position: (.attributes.current_position // null),
      features: (.attributes.supported_features // 15),
      device_class: (.attributes.device_class // "")
    }]'
}

cmd_test() {
  load_config
  curl_ha GET /api/states
  if [[ "$HTTP_CODE" == "200" ]]; then
    printf '%s' "$BODY" | jq -c '[.[] | select(.entity_id | startswith("cover."))] | length
      | {ok:true,code:200,data:{covers:.}}'
    return 0
  fi
  jq -nc --arg e "$(http_error_message "$HTTP_CODE")" --argjson c "${HTTP_CODE:-0}" \
    '{ok:false,code:$c,error:$e}'
}

# service <open|close|stop> <entity_id> [entity_id...]
cmd_service() {
  local action="$1"; shift
  case "$action" in
    open) svc=open_cover ;;
    close) svc=close_cover ;;
    stop) svc=stop_cover ;;
    *) die "Unknown action: $action" ;;
  esac
  [[ $# -gt 0 ]] || die "No entity specified"
  load_config
  local body
  body="$(printf '%s\n' "$@" | jq -Rn '{entity_id: [inputs | select(length > 0)]}')"
  curl_ha POST "/api/services/cover/$svc" "$body"
  emit_or_fail '.'
}

# position <0-100> <entity_id> [entity_id...]
cmd_position() {
  local position="$1"; shift
  [[ "$position" =~ ^[0-9]+$ ]] || die "Position must be a number between 0 and 100"
  position=$((10#$position))
  (( position >= 0 && position <= 100 )) || die "Position must be between 0 and 100"
  [[ $# -gt 0 ]] || die "No entity specified"
  load_config
  local body
  body="$(printf '%s\n' "$@" | jq -Rn --argjson p "$position" \
    '{entity_id: [inputs | select(length > 0)], position: $p}')"
  curl_ha POST /api/services/cover/set_cover_position "$body"
  emit_or_fail '.'
}

cmd_areas() {
  load_config
  local template body
  template='[{% for s in states.cover %}{"entity_id": {{ s.entity_id | tojson }}, "area": {{ (area_name(s.entity_id) or "") | tojson }}, "floor": {{ (floor_name(area_id(s.entity_id)) or "") | tojson }}}{{ "," if not loop.last }}{% endfor %}]'
  body="$(jq -nc --arg t "$template" '{template:$t}')"
  curl_ha POST /api/template "$body"
  if [[ "$HTTP_CODE" == "200" ]] && printf '%s' "$BODY" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$BODY" | jq -c '{ok:true,code:200,data:.}'
    return 0
  fi
  # Area/floor discovery is best-effort: report a soft failure so the caller
  # can silently fall back to the name heuristic.
  jq -nc --arg e "$(http_error_message "$HTTP_CODE")" --argjson c "${HTTP_CODE:-0}" \
    '{ok:false,code:$c,error:$e}'
}

# Reads the full settings JSON on stdin and stores it 0600.
cmd_save() {
  local payload dir tmp
  payload="$(cat)"
  printf '%s' "$payload" | jq -e . >/dev/null 2>&1 || die "Invalid settings"
  dir="$(dirname "$CONF")"
  mkdir -p "$dir" || die "Could not create $dir"
  tmp="$(mktemp "$dir/.shutters.XXXXXX")" || die "mktemp failed"
  chmod 600 "$tmp"
  printf '%s\n' "$payload" >"$tmp" || { rm -f "$tmp"; die "Write failed"; }
  mv -f "$tmp" "$CONF" || { rm -f "$tmp"; die "Write failed"; }
  chmod 600 "$CONF"
  jq -nc '{ok:true,code:0,data:"saved"}'
}

ensure_deps
[[ $# -gt 0 ]] || die "No command specified"
command="$1"; shift
case "$command" in
  states) cmd_states ;;
  test) cmd_test ;;
  service) cmd_service "$@" ;;
  position) cmd_position "$@" ;;
  areas) cmd_areas ;;
  save) cmd_save ;;
  *) die "Unknown command: $command" ;;
esac
