#!/usr/bin/env bash

resolve_script_path() {
  local source_path="$0"
  if [[ "$source_path" != */* ]]; then
    source_path=$(command -v "$source_path" 2>/dev/null || printf '%s' "$source_path")
  fi

  local source_dir source_name
  source_dir=$(cd "$(dirname "$source_path")" 2>/dev/null && pwd)
  source_name=$(basename "$source_path")
  printf '%s/%s\n' "$source_dir" "$source_name"
}

is_path_invocation() {
  local invoked_name
  invoked_name=$(basename "$0")

  if [[ "$invoked_name" == *.sh ]]; then
    return 1
  fi

  return 0
}

home_for_user() {
  local user_name="$1"
  local user_home=""

  if command -v getent >/dev/null 2>&1; then
    user_home=$(getent passwd "$user_name" | cut -d: -f6)
  elif command -v dscl >/dev/null 2>&1; then
    user_home=$(dscl . -read "/Users/$user_name" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  fi

  if [ -z "$user_home" ] && command -v python3 >/dev/null 2>&1; then
    user_home=$(python3 -c '
import pwd, sys
try:
    print(pwd.getpwnam(sys.argv[1]).pw_dir)
except KeyError:
    pass
' "$user_name" 2>/dev/null)
  fi

  printf '%s\n' "$user_home"
}

get_effective_home() {
  if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    local sudo_home
    sudo_home=$(home_for_user "$SUDO_USER")
    if [ -n "$sudo_home" ]; then
      printf '%s\n' "$sudo_home"
      return
    fi
  fi

  if [ -n "$HOME" ]; then
    printf '%s\n' "$HOME"
    return
  fi

  home_for_user "$(id -un)"
}

expand_user_path() {
  local path_value="$1"

  case "$path_value" in
    "~")
      printf '%s\n' "$EFFECTIVE_HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$EFFECTIVE_HOME" "${path_value#~/}"
      ;;
    *)
      printf '%s\n' "$path_value"
      ;;
  esac
}

is_valid_provider() {
  case "$1" in
    gemini|openai|claude) return 0 ;;
    *) return 1 ;;
  esac
}

debug_log() {
  if [ "$DEBUG_MODE" -eq 1 ]; then
    printf '%s\n' "$*"
  fi
}

debug_payload() {
  local payload="$1"
  if [ "$DEBUG_MODE" -eq 1 ]; then
    printf '%s\n' "[DEBUG] Payload:"
    printf '%s' "$payload" | python3 -m json.tool
    printf '\n'
  fi
}

escape_for_double_quotes() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\$/\\\$}
  value=${value//\`/\\\`}
  printf '%s\n' "$value"
}

write_config_file() {
  local system_prompt="$1"
  local provider="$2"
  local model="$3"
  local api_key="$4"

  mkdir -p "$(dirname "$WRITE_ENV_FILE")" || {
    printf '%s\n' "Failed to create config directory: $(dirname "$WRITE_ENV_FILE")"
    return 1
  }

  {
    printf 'SYSTEM_PROMPT=\"%s\"\n' "$(escape_for_double_quotes "$system_prompt")"
    printf 'PROVIDER=%q\n' "$provider"
    printf 'MODEL=%q\n' "$model"
    printf 'API_KEY=%q\n' "$api_key"
  } > "$WRITE_ENV_FILE"
}

get_write_config_path() {
  if [ -n "$CONFIG_OVERRIDE" ]; then
    printf '%s\n' "$CONFIG_OVERRIDE"
    return
  fi

  if is_path_invocation; then
    printf '%s\n' "$HOME_ENV_FILE"
    return
  fi

  printf '%s\n' "$CWD_ENV_FILE"
}

load_config_with_precedence() {
  ACTIVE_CONFIG_FILE=""
  CONFIG_LOAD_ERROR=""

  if [ -n "$CONFIG_OVERRIDE" ]; then
    if [ -r "$CONFIG_OVERRIDE" ]; then
      set -a
      # shellcheck source=/dev/null
      source "$CONFIG_OVERRIDE"
      set +a
      ACTIVE_CONFIG_FILE="$CONFIG_OVERRIDE"
      return 0
    fi
    CONFIG_LOAD_ERROR="CLUD_CONFIG points to a missing or unreadable file: $CONFIG_OVERRIDE"
    return 1
  fi

  if [ -r "$CWD_ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$CWD_ENV_FILE"
    set +a
    ACTIVE_CONFIG_FILE="$CWD_ENV_FILE"
    return 0
  fi

  if [ -r "$HOME_ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$HOME_ENV_FILE"
    set +a
    ACTIVE_CONFIG_FILE="$HOME_ENV_FILE"
    return 0
  fi

  return 0
}

SCRIPT_PATH=$(resolve_script_path)
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
EFFECTIVE_HOME=$(get_effective_home)
CWD_ENV_FILE="$PWD/.clud.env"
HOME_ENV_FILE="$EFFECTIVE_HOME/.clud.env"
CONFIG_OVERRIDE=$(expand_user_path "${CLUD_CONFIG:-}")
WRITE_ENV_FILE=$(get_write_config_path)
ACTIVE_CONFIG_FILE=""
CONFIG_LOAD_ERROR=""
DEBUG_MODE=0

# ─── SELF COMMAND NAME ────────────────────────────────────────────────────────
get_self_cmd() {
  local name
  name="$(basename "$0")"
  case "$name" in
    *.sh) printf '%s\n' "sh $name" ;;
    *)    printf '%s\n' "$name" ;;
  esac
}
SELF_CMD_NAME="$(get_self_cmd)"

# ─── USAGE ────────────────────────────────────────────────────────────────────
print_usage() {
  printf '%s\n' "clud — ask an AI for a shell command"
  printf '\n'
  printf '%s\n' "Usage:"
  printf '%s\n' "  $SELF_CMD_NAME <your query>"
  printf '\n'
  printf '%s\n' "Flags:"
  printf '%s\n' "  -h, --help      show this help"
  printf '%s\n' "  -d, --debug     enable debug logs ([DEBUG] lines)"
  printf '%s\n' "  -s, --setup     configure provider, model, and API key"
  printf '%s\n' "  -i, --install   copy this script to an executable on your PATH"
  printf '%s\n' "      --doctor    check dependencies and config health"
}

# ─── AUTO-DETECT SYSTEM ───────────────────────────────────────────────────────
detect_system() {
  local product version arch
  if [[ "$OSTYPE" == "darwin"* ]]; then
    product=$(sw_vers -productName 2>/dev/null || printf '%s\n' "macOS")
    version=$(sw_vers -productVersion 2>/dev/null || printf '%s\n' "")
    arch=$(uname -m)
    [[ "$arch" == "arm64" ]] && arch="Apple Silicon" || arch="Intel"
    printf '%s\n' "${product} ${version} ${arch}"
  elif [ -f /etc/os-release ]; then
    . /etc/os-release
    arch=$(uname -m)
    printf '%s\n' "${NAME} ${VERSION_ID:-} ${arch}"
  else
    printf '%s\n' "$(uname -s) $(uname -r) $(uname -m)"
  fi
}

# ─── LOADING SPINNER ──────────────────────────────────────────────────────────
run_request_with_spinner() {
  local tmp_file pid status i
  local -a spin
  tmp_file=$(mktemp)

  "$@" >"$tmp_file" &
  pid=$!

  if [ -t 1 ]; then
    spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$(( (i + 1) % ${#spin[@]} ))
      printf "\r%s" "${spin[$i]}"
      sleep 0.1
    done
  fi

  wait "$pid"
  status=$?

  if [ -t 1 ]; then
    printf "\r \r"
  fi

  RESPONSE=$(cat "$tmp_file")
  rm -f "$tmp_file"
  return $status
}

# ─── SETUP ────────────────────────────────────────────────────────────────────
run_setup() {
  local detected system_input system_desc
  local provider_choice provider provider_label
  local -a model_options model_values
  local existing_api_key api_key_input
  local model_choice model
  local system_prompt system_prompt_input

  printf '\n'

  # System
  detected=$(detect_system)
  printf '%s\n' "Which system are you running on?"
  printf '%s\n' "  Detected: $detected"
  read -r -p "  Press enter to accept, or type to override: " system_input
  system_desc="${system_input:-$detected}"
  printf '%s\n' "  Using: $system_desc"
  printf '\n'

  # Provider
  printf '%s\n' "Which provider do you want to use?"
  printf '%s\n' "  1) Google     (Gemini)"
  printf '%s\n' "  2) Anthropic  (Claude)"
  printf '%s\n' "  3) OpenAI     (ChatGPT)"
  read -r -p "  Choice [1-3]: " provider_choice
  printf '\n'

  case "$provider_choice" in
    1)
      provider="gemini"
      provider_label="Google Gemini"
      model_options=(
        "gemini-2.5-flash-lite   — fastest and cheapest (recommended)"
        "gemini-3.0-flash        — newest flash model"
        "gemini-2.5-flash        — fast and capable"
      )
      model_values=("gemini-2.5-flash-lite" "gemini-3.0-flash" "gemini-2.5-flash")
      ;;
    2)
      provider="claude"
      provider_label="Anthropic Claude"
      model_options=(
        "claude-haiku-4-5-20251001  — fastest and cheapest (recommended)"
        "claude-sonnet-4-6          — smarter, moderate cost"
      )
      model_values=("claude-haiku-4-5-20251001" "claude-sonnet-4-6")
      ;;
    3)
      provider="openai"
      provider_label="OpenAI"
      model_options=(
        "gpt-4o-mini             — fast and cheap (recommended)"
        "gpt-4o                  — smarter, higher cost"
      )
      model_values=("gpt-4o-mini" "gpt-4o")
      ;;
    *)
      printf '%s\n' "Invalid choice. Aborting."
      exit 1
      ;;
  esac

  # API key
  existing_api_key=""
  if [ -r "$WRITE_ENV_FILE" ]; then
    existing_api_key=$(bash -c 'set -a; source "$1" 2>/dev/null; printf "%s" "$API_KEY"' _ "$WRITE_ENV_FILE")
  fi

  printf '%s\n' "API key for $provider_label:"
  if [ -n "$existing_api_key" ]; then
    read -r -p "  > (leave empty to keep existing) " api_key_input
  else
    read -r -p "  > " api_key_input
  fi

  if [ -z "$api_key_input" ] && [ -n "$existing_api_key" ]; then
    api_key_input="$existing_api_key"
  fi

  if [ -z "$api_key_input" ]; then
    printf '%s\n' "No API key entered. Aborting."
    exit 1
  fi
  printf '\n'

  # Model
  printf '%s\n' "Which model to use?"
  for i in "${!model_options[@]}"; do
    printf '%s\n' "  $((i + 1))) ${model_options[$i]}"
  done
  read -r -p "  Choice [1-${#model_options[@]}] (default 1): " model_choice
  model_choice="${model_choice:-1}"
  model="${model_values[$((model_choice - 1))]}"
  if [ -z "$model" ]; then
    model="${model_values[0]}"
  fi
  printf '%s\n' "  Using: $model"
  printf '\n'

  # Build system prompt
  system_prompt="You are a shell command assistant. The user is running: ${system_desc}. \
When given a task, respond with a single, complete, ready-to-execute shell command. \
Rules: no explanations, no markdown, no backticks, no comments. \
If multiple steps are needed, chain them with && or write a one-liner. \
Prefer standard, widely-available tools with minimal dependencies. \
The command must run correctly without any modification."

  printf '%s\n' "System prompt:"
  printf '%s\n' "---"
  printf '%s\n' "$system_prompt"
  printf '%s\n' "---"
  read -r -p "Press enter to accept, or type a custom system prompt: " system_prompt_input
  system_prompt="${system_prompt_input:-$system_prompt}"
  printf '\n'

  write_config_file "$system_prompt" "$provider" "$model" "$api_key_input" || exit 1

  printf '%s\n' "Saved to: $WRITE_ENV_FILE"
}

# ─── DOCTOR ───────────────────────────────────────────────────────────────────
run_doctor() {
  local failures=0

  printf '%s\n' "Running checks..."

  for dep in bash curl python3; do
    if command -v "$dep" >/dev/null 2>&1; then
      printf '%s\n' "[ OK ] Found dependency: $dep"
    else
      printf '%s\n' "[FAIL] Missing dependency: $dep"
      failures=$((failures + 1))
    fi
  done

  if ! load_config_with_precedence; then
    printf '%s\n' "[FAIL] $CONFIG_LOAD_ERROR"
    failures=$((failures + 1))
  elif [ -n "$ACTIVE_CONFIG_FILE" ]; then
    printf '%s\n' "[ OK ] Found config at: $ACTIVE_CONFIG_FILE"

    if [ -n "$PROVIDER" ] && ! is_valid_provider "$PROVIDER"; then
      printf '%s\n' "[FAIL] Invalid provider in config: $PROVIDER"
      failures=$((failures + 1))
    fi
  else
    printf '%s\n' "[FAIL] No config found, run --setup"
    failures=$((failures + 1))
  fi

  if command -v clud >/dev/null 2>&1; then
    printf '%s\n' "[ OK ] Installed command found: $(command -v clud)"
  else
    printf '%s\n' "[INFO] clud not in PATH, run --install"
  fi

  if [ "$failures" -eq 0 ]; then
    printf '%s\n' "All checks passed."
    return 0
  fi

  printf '%s\n' "Doctor found $failures issue(s)."
  return 1
}

# ─── INSTALL ──────────────────────────────────────────────────────────────────
run_install() {
  local default_dir="/usr/local/bin"
  local default_name="clud"
  local install_dir install_name target_path
  local home_config_dir home_dir_existed

  printf '%s\n' "Install clud executable"
  read -r -p "Install directory [$default_dir]: " install_dir
  install_dir="${install_dir:-$default_dir}"
  install_dir=$(expand_user_path "$install_dir")

  read -r -p "Executable name [$default_name]: " install_name
  install_name="${install_name:-$default_name}"

  target_path="${install_dir%/}/$install_name"

  if [ ! -d "$install_dir" ]; then
    read -r -p "Directory does not exist. Create $install_dir? [y/N] " create_dir
    if [[ "$create_dir" =~ ^[Yy]$ ]]; then
      mkdir -p "$install_dir" || {
        printf '%s\n' "Failed to create directory: $install_dir"
        return 1
      }
    else
      printf '%s\n' "Install cancelled."
      return 1
    fi
  fi

  if [ -e "$target_path" ]; then
    printf '%s\n' "Target already exists. Aborting without overwrite: $target_path"
    return 1
  fi

  cp "$SCRIPT_PATH" "$target_path" 2>/dev/null || {
    printf '%s\n' "Failed to copy script to $target_path"
    printf '%s\n' "You may need elevated permissions. Retry with:"
    printf '%s\n' "  sudo cp \"$SCRIPT_PATH\" \"$target_path\" && sudo chmod +x \"$target_path\""
    return 1
  }

  chmod +x "$target_path" 2>/dev/null || {
    printf '%s\n' "Failed to mark executable: $target_path"
    printf '%s\n' "You may need elevated permissions. Retry with:"
    printf '%s\n' "  sudo chmod +x \"$target_path\""
    return 1
  }

  printf '%s\n' "Installed: $target_path"
  
  if [ -f "$CWD_ENV_FILE" ] && [ ! -f "$HOME_ENV_FILE" ]; then
    read -r -p "Found local config at $CWD_ENV_FILE but no home config. Copy to $HOME_ENV_FILE? [y/N] " copy_local_to_home
    if [[ "$copy_local_to_home" =~ ^[Yy]$ ]]; then
      home_config_dir=$(dirname "$HOME_ENV_FILE")
      home_dir_existed=0
      if [ -d "$home_config_dir" ]; then
        home_dir_existed=1
      fi

      mkdir -p "$home_config_dir" || {
        printf '%s\n' "Failed to create home config directory: $home_config_dir"
        return 1
      }

      cp "$CWD_ENV_FILE" "$HOME_ENV_FILE" || {
        printf '%s\n' "Failed to copy config to: $HOME_ENV_FILE"
        return 1
      }

      if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        local sudo_group owner_spec
        sudo_group=$(id -gn "$SUDO_USER" 2>/dev/null)
        if [ -n "$sudo_group" ]; then
          owner_spec="$SUDO_USER:$sudo_group"
        else
          owner_spec="$SUDO_USER"
        fi

        if [ "$home_dir_existed" -eq 0 ]; then
          chown "$owner_spec" "$home_config_dir" || {
            printf '%s\n' "Failed to set ownership on directory: $home_config_dir"
            return 1
          }
        fi

        chown "$owner_spec" "$HOME_ENV_FILE" || {
          printf '%s\n' "Failed to set ownership on config: $HOME_ENV_FILE"
          return 1
        }
      fi

      chmod 600 "$HOME_ENV_FILE" || {
        printf '%s\n' "Failed to set config permissions (600): $HOME_ENV_FILE"
        return 1
      }

      printf '%s\n' "Copied config to: $HOME_ENV_FILE"
      printf '\n'
    fi
  fi
}

# ─── QUERY ────────────────────────────────────────────────────────────────────
run_query() {
  local user_input payload cmd confirm

  if ! load_config_with_precedence; then
    printf '%s\n' "$CONFIG_LOAD_ERROR"
    exit 1
  fi

  if [ -z "$PROVIDER" ] || [ -z "$API_KEY" ] || [ -z "$SYSTEM_PROMPT" ]; then
    if [ -n "$ACTIVE_CONFIG_FILE" ]; then
      printf '%s\n' "Config loaded from $ACTIVE_CONFIG_FILE but required fields are missing."
    else
      printf '%s\n' "No config found (checked: $CWD_ENV_FILE then $HOME_ENV_FILE)."
    fi
    printf '%s\n' "Starting setup. Config will be written to: $WRITE_ENV_FILE"
    run_setup
    exit 0
  fi

  user_input="$*"

  case "$PROVIDER" in

    gemini)
      payload=$(python3 -c "
import json, sys
print(json.dumps({
    'system_instruction': {'parts': [{'text': sys.argv[1]}]},
    'contents': [{'parts': [{'text': sys.argv[2]}]}]
}))
" "$SYSTEM_PROMPT" "$user_input")

      debug_log "[DEBUG] Provider: Gemini  Model: $MODEL"
      debug_payload "$payload"

      run_request_with_spinner curl -s \
        "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${API_KEY}" \
        -H "Content-Type: application/json" -d "$payload" || {
          printf '%s\n' "Gemini request failed."
          exit 1
        }

      cmd=$(printf '%s' "$RESPONSE" | python3 -c "
import sys, json
data = json.JSONDecoder(strict=False).decode(sys.stdin.read())
try:    print(data['candidates'][0]['content']['parts'][0]['text'].strip())
except: print('Error:', json.dumps(data, indent=2), file=sys.stderr); sys.exit(1)
")
      ;;

    openai)
      payload=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[3],
    'messages': [{'role': 'system', 'content': sys.argv[1]}, {'role': 'user', 'content': sys.argv[2]}]
}))
" "$SYSTEM_PROMPT" "$user_input" "$MODEL")

      debug_log "[DEBUG] Provider: OpenAI  Model: $MODEL"
      debug_payload "$payload"

      run_request_with_spinner curl -s "https://api.openai.com/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_KEY}" \
        -d "$payload" || {
          printf '%s\n' "OpenAI request failed."
          exit 1
        }

      cmd=$(printf '%s' "$RESPONSE" | python3 -c "
import sys, json
data = json.JSONDecoder(strict=False).decode(sys.stdin.read())
try:    print(data['choices'][0]['message']['content'].strip())
except: print('Error:', json.dumps(data, indent=2), file=sys.stderr); sys.exit(1)
")
      ;;

    claude)
      payload=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[3],
    'max_tokens': 256,
    'system': sys.argv[1],
    'messages': [{'role': 'user', 'content': sys.argv[2]}]
}))
" "$SYSTEM_PROMPT" "$user_input" "$MODEL")

      debug_log "[DEBUG] Provider: Claude  Model: $MODEL"
      debug_payload "$payload"

      run_request_with_spinner curl -s "https://api.anthropic.com/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -d "$payload" || {
          printf '%s\n' "Claude request failed."
          exit 1
        }

      cmd=$(printf '%s' "$RESPONSE" | python3 -c "
import sys, json
data = json.JSONDecoder(strict=False).decode(sys.stdin.read())
try:    print(data['content'][0]['text'].strip())
except: print('Error:', json.dumps(data, indent=2), file=sys.stderr); sys.exit(1)
")
      ;;

    *)
      printf '%s\n' "Unknown provider '$PROVIDER'. Run: $SELF_CMD_NAME --setup"
      exit 1
      ;;
  esac

  [ $? -ne 0 ] && exit 1

  printf '%s\n' "Suggested command:"
  printf '%s\n' "  $cmd"
  printf '\n'
  read -r -p "Run it? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] && bash -lc "$cmd"
}

# ─── ENTRYPOINT ───────────────────────────────────────────────────────────────
while [[ "$1" == "-d" || "$1" == "--debug" ]]; do
  DEBUG_MODE=1
  shift
done

case "$1" in
  -h|--help|"")
    print_usage
    ;;
  -s|--setup)
    run_setup
    ;;
  -i|--install)
    run_install
    ;;
  --doctor)
    run_doctor
    ;;
  -*)
    printf '%s\n' "Invalid argument"
    exit 1
    ;;
  *)
    run_query "$@"
    ;;
esac
