#!/usr/bin/env bash

if [[ -n "${OPS_UI_LOADED:-}" ]]; then
  return 0
fi
readonly OPS_UI_LOADED=1

OPS_UI_READY=0
OPS_UI_UTF8=0
OPS_UI_WIDTH=64
OPS_UI_RESET=''
OPS_UI_BOLD=''
OPS_UI_DIM=''
OPS_UI_CYAN=''
OPS_UI_GREEN=''
OPS_UI_YELLOW=''
OPS_UI_BLUE=''
OPS_UI_SEP=' | '
OPS_UI_PROMPT_MARK='>'
OPS_UI_ELLIPSIS='...'

ops_ui_die() {
  if declare -F ops_die >/dev/null 2>&1; then
    ops_die "$@"
  fi
  printf '[ops-toolkit] ERROR: %s\n' "$*" >&2
  exit 1
}

ops_ui_require_tty() {
  [[ -t 0 ]] || ops_ui_die 'This menu requires an interactive terminal.'
}

ops_ui_update_width() {
  local cols
  OPS_UI_WIDTH=64
  [[ -t 1 ]] || return 0
  cols=$(tput cols 2>/dev/null || true)
  [[ -z $cols && -n ${COLUMNS:-} ]] && cols=$COLUMNS
  [[ $cols =~ ^[0-9]+$ ]] || return 0
  if ((cols < 48)); then
    OPS_UI_WIDTH=48
  elif ((cols > 72)); then
    OPS_UI_WIDTH=72
  else
    OPS_UI_WIDTH=$cols
  fi
}

ops_ui_init() {
  if ((OPS_UI_READY)); then
    ops_ui_update_width
    return 0
  fi

  OPS_UI_WIDTH=64
  OPS_UI_UTF8=0
  OPS_UI_RESET=''
  OPS_UI_BOLD=''
  OPS_UI_DIM=''
  OPS_UI_CYAN=''
  OPS_UI_GREEN=''
  OPS_UI_YELLOW=''
  OPS_UI_BLUE=''
  OPS_UI_SEP=' | '
  OPS_UI_PROMPT_MARK='>'
  OPS_UI_ELLIPSIS='...'

  ops_ui_update_width

  if [[ -t 1 ]]; then
    local colors
    if [[ -z ${NO_COLOR:-} && ${OPS_UI_NO_COLOR:-0} != 1 ]]; then
      colors=$(tput colors 2>/dev/null || echo 0)
      if [[ -n ${COLORTERM:-} ]] || { [[ $colors =~ ^[0-9]+$ ]] && ((colors >= 8)); }; then
        OPS_UI_RESET=$'\033[0m'
        OPS_UI_BOLD=$'\033[1m'
        OPS_UI_DIM=$'\033[2m'
        OPS_UI_CYAN=$'\033[36m'
        OPS_UI_GREEN=$'\033[32m'
        OPS_UI_YELLOW=$'\033[33m'
        OPS_UI_BLUE=$'\033[34m'
      fi
    fi
  fi

  local locale=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  # Match UTF-8 / utf8 / UTF8 with optional hyphen/underscore before 8.
  if [[ $locale == *[Uu][Tt][Ff][-_]?8* || $locale == *[Uu][Tt][Ff]8* ]]; then
    OPS_UI_UTF8=1
    OPS_UI_SEP=' · '
    OPS_UI_PROMPT_MARK='›'
    OPS_UI_ELLIPSIS='…'
  fi

  OPS_UI_READY=1
}

ops_ui_clear() {
  ops_ui_init
  [[ -t 1 ]] || return 0
  # Prefer scrollback-preserving clear so status/config output remains readable.
  if command -v clear >/dev/null 2>&1; then
    clear -x 2>/dev/null || clear 2>/dev/null || printf '\033[H\033[2J'
  else
    printf '\033[H\033[2J'
  fi
}

ops_ui_repeat() {
  local char=$1 count=$2 i
  ((count > 0)) || return 0
  for ((i = 0; i < count; i++)); do
    printf '%s' "$char"
  done
}

ops_ui_rule() {
  ops_ui_init
  local style=${1:-light} char
  if ((OPS_UI_UTF8)); then
    case $style in
      heavy) char='═' ;;
      *) char='─' ;;
    esac
  else
    case $style in
      heavy) char='=' ;;
      *) char='-' ;;
    esac
  fi
  printf '%s' "${OPS_UI_DIM}"
  ops_ui_repeat "$char" "$OPS_UI_WIDTH"
  printf '%s\n' "${OPS_UI_RESET}"
}

ops_ui_header() {
  ops_ui_init
  local title=$1
  local privilege platform identity

  if ((EUID == 0)); then
    privilege=root
  else
    privilege=${USER:-$(id -un 2>/dev/null || echo user)}
  fi
  platform=$(ops_platform_label 2>/dev/null || printf 'unknown')
  identity="ops-toolkit ${OPS_VERSION:-?}${OPS_UI_SEP}${platform}${OPS_UI_SEP}${privilege}"

  printf '\n'
  ops_ui_rule heavy
  printf '  %s%s%s\n' "${OPS_UI_BOLD}${OPS_UI_CYAN}" "$identity" "${OPS_UI_RESET}"
  ops_ui_rule light
  printf '  %s%s%s\n\n' "${OPS_UI_BOLD}" "$title" "${OPS_UI_RESET}"
}

ops_ui_footer() {
  ops_ui_init
  local hint=${1:-Enter a number, then press Enter}
  printf '\n'
  ops_ui_rule light
  printf '  %s%s%s\n' "${OPS_UI_DIM}" "$hint" "${OPS_UI_RESET}"
  ops_ui_rule heavy
  printf '\n'
}

ops_ui_trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

ops_ui_sleep_brief() {
  # Best-effort delay after invalid input; never fail the shell under set -e.
  sleep 0.8 2>/dev/null || sleep 1 2>/dev/null || true
}

# ops_ui_menu OUT_VAR TITLE [HINT] -- ITEM...
# Each ITEM is KEY|LABEL or KEY|LABEL|NOTE
# EOF / Ctrl-D selects key "0" when present (Back/Exit), otherwise returns 1.
ops_ui_menu() {
  ops_ui_require_tty

  local out_var=$1 title=$2
  shift 2
  local hint=''
  if [[ ${1:-} == -- ]]; then
    shift
  elif [[ ${2:-} == -- ]]; then
    hint=$1
    shift 2
  elif [[ ${1:-} != *'|'* && $# -gt 0 ]]; then
    hint=$1
    shift
  fi

  local -a items=("$@") keys=() labels=() notes=()
  local item key label note rest key_width=1 answer k valid i

  ((${#items[@]} > 0)) || ops_ui_die 'ops_ui_menu requires at least one item.'

  ops_ui_init
  if [[ -z $hint ]]; then
    hint="Enter a number, then press Enter"
  fi

  for item in "${items[@]}"; do
    [[ $item == *'|'* ]] || ops_ui_die "Invalid menu item (expected KEY|LABEL): $item"
    key=${item%%|*}
    rest=${item#*|}
    [[ -n $key ]] || ops_ui_die "Invalid menu item (empty key): $item"
    if [[ $rest == *'|'* ]]; then
      label=${rest%%|*}
      note=${rest#*|}
    else
      label=$rest
      note=''
    fi
    keys+=("$key")
    labels+=("$label")
    notes+=("$note")
    if ((${#key} > key_width)); then
      key_width=${#key}
    fi
  done

  while true; do
    ops_ui_clear
    ops_ui_header "$title"

    for i in "${!keys[@]}"; do
      key=${keys[i]}
      label=${labels[i]}
      note=${notes[i]}
      printf '    %s%*s%s)  %s' "${OPS_UI_BOLD}${OPS_UI_GREEN}" "$key_width" "$key" "${OPS_UI_RESET}" "$label"
      if [[ -n $note ]]; then
        printf '  %s%s%s' "${OPS_UI_DIM}" "$note" "${OPS_UI_RESET}"
      fi
      printf '\n'
    done

    ops_ui_footer "$hint"
    printf '%sSelect %s%s ' "${OPS_UI_BOLD}${OPS_UI_CYAN}" "${OPS_UI_PROMPT_MARK}" "${OPS_UI_RESET}"
    if ! read -r answer; then
      printf '\n'
      for k in "${keys[@]}"; do
        if [[ $k == 0 ]]; then
          printf -v "$out_var" '%s' '0'
          return 0
        fi
      done
      return 1
    fi
    answer=$(ops_ui_trim "$answer")
    [[ -n $answer ]] || continue

    valid=0
    for k in "${keys[@]}"; do
      if [[ $answer == "$k" || ${answer,,} == "${k,,}" ]]; then
        valid=1
        answer=$k
        break
      fi
    done
    if ((valid)); then
      printf -v "$out_var" '%s' "$answer"
      return 0
    fi
    printf '%sInvalid selection: %s%s\n' "${OPS_UI_YELLOW}" "$answer" "${OPS_UI_RESET}"
    ops_ui_sleep_brief
  done
}

# ops_ui_prompt OUT_VAR LABEL [DEFAULT]
# Empty Enter keeps DEFAULT when provided.
# EOF / Ctrl-D prints Cancelled and returns 1 without applying DEFAULT (soft cancel).
ops_ui_prompt() {
  local out_var=$1 label=$2 default=${3-}
  local answer display
  ops_ui_init
  if [[ -n $default ]]; then
    display=$(printf '%s [%s]' "$label" "$default")
  else
    display=$label
  fi
  printf '%s%s %s%s ' "${OPS_UI_BOLD}${OPS_UI_BLUE}" "$display" "${OPS_UI_PROMPT_MARK}" "${OPS_UI_RESET}"
  if ! read -r answer; then
    printf '\n%sCancelled.%s\n' "${OPS_UI_YELLOW}" "${OPS_UI_RESET}"
    printf -v "$out_var" '%s' ''
    return 1
  fi
  answer=$(ops_ui_trim "$answer")
  if [[ -z $answer && -n $default ]]; then
    answer=$default
  fi
  printf -v "$out_var" '%s' "$answer"
  return 0
}

# ops_ui_confirm PROMPT [default_y|default_n]
# Returns 0 for yes, 1 for no / EOF. Never exits the process.
ops_ui_confirm() {
  local prompt=$1 mode=${2:-default_n}
  local answer suffix
  ops_ui_init

  if ((OPS_DRY_RUN || OPS_ASSUME_YES)); then
    return 0
  fi

  case $mode in
    default_y | Y | y) suffix='[Y/n]' ;;
    *)
      mode=default_n
      suffix='[y/N]'
      ;;
  esac

  printf '%s%s %s %s%s ' "${OPS_UI_BOLD}${OPS_UI_BLUE}" "$prompt" "$suffix" "${OPS_UI_PROMPT_MARK}" "${OPS_UI_RESET}"
  if ! read -r answer; then
    printf '\n'
    return 1
  fi
  answer=$(ops_ui_trim "$answer")
  if [[ -z $answer ]]; then
    [[ $mode == default_y ]]
    return
  fi
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

ops_ui_pause() {
  ops_ui_init
  [[ -t 0 ]] || return 0
  printf '\n%sPress Enter to continue%s%s ' "${OPS_UI_DIM}" "${OPS_UI_ELLIPSIS}" "${OPS_UI_RESET}"
  # EOF while pausing just continues; never abort mid-cleanup display.
  read -r _ || true
}
