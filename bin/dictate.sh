#!/bin/bash
# dictate.sh — голосовая диктовка с коррекцией текста через OpenCode.
#
# Использование:
#   dictate.sh toggle        # ⌥Space: начать запись / остановить и вставить
#   dictate.sh start|stop    # явные команды (для отладки)
#   dictate.sh cancel        # отменить запись без распознавания и вставки
#
# Отладка:
#   DICTATE_DRY_RUN=1             не вставлять, только вывести RAW/FIXED
#   DICTATE_RESTORE_CLIPBOARD=1   вернуть прежний буфер обмена
#   DICTATE_DEBOUNCE_MS=500       окно подавления авто-повтора клавиши

set -uo pipefail
umask 077

# каталог, где лежат скрипт и собранные помощники (pastev, dictatehud)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ACTION="${1:-toggle}"

# ---------- PATH и локаль (skhd/launchd дают урезанное окружение) ----------
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
# без UTF-8 локали pbcopy портит кириллицу (UTF-8 -> MacRoman)
export LC_CTYPE=UTF-8
export LANG="${LANG:-en_US.UTF-8}"
unset LC_ALL

# ---------- настройки ----------
BUNDLE_WHISPER="$SCRIPT_DIR/whisper"

WHISPER_CLI_BIN="${WHISPER_CLI_BIN:-${WHISPER_BIN:-}}"
if [ -z "$WHISPER_CLI_BIN" ]; then
  if [ -x "$BUNDLE_WHISPER/bin/whisper-cli" ]; then
    WHISPER_CLI_BIN="$BUNDLE_WHISPER/bin/whisper-cli"
  else
    WHISPER_CLI_BIN="whisper-cli"
  fi
fi

WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin}"

WHISPER_VAD_MODEL="${WHISPER_VAD_MODEL:-}"
if [ -z "$WHISPER_VAD_MODEL" ]; then
  if [ -f "$BUNDLE_WHISPER/models/ggml-silero-v5.1.2.bin" ]; then
    WHISPER_VAD_MODEL="$BUNDLE_WHISPER/models/ggml-silero-v5.1.2.bin"
  else
    WHISPER_VAD_MODEL="$HOME/.local/share/whisper/ggml-silero-v5.1.2.bin"
  fi
fi

WHISPER_LANG="${WHISPER_LANG:-ru}"
WHISPER_THREADS="${WHISPER_THREADS:-8}"
MIC_NAME="${MIC_NAME:-}"

OC_PROVIDER="${OC_PROVIDER:-deepseek}"
OC_MODEL_ID="${OC_MODEL_ID:-deepseek-flash}"
OC_VARIANT="${OC_VARIANT:-none}"          # none = без «мышления» (заметно быстрее)

WHISPER_SERVER_BIN="${WHISPER_SERVER_BIN:-}"
if [ -z "$WHISPER_SERVER_BIN" ]; then
  if [ -x "$BUNDLE_WHISPER/bin/whisper-server" ]; then
    WHISPER_SERVER_BIN="$BUNDLE_WHISPER/bin/whisper-server"
  else
    WHISPER_SERVER_BIN="whisper-server"
  fi
fi
WHISPER_SERVER_PORT="${WHISPER_SERVER_PORT:-8799}"

NOTIFY="${DICTATE_NOTIFY:-1}"
RESTORE_CLIPBOARD="${DICTATE_RESTORE_CLIPBOARD:-0}"
HUD_BIN="${HUD_BIN:-$SCRIPT_DIR/dictatehud}"
DRY_RUN="${DICTATE_DRY_RUN:-0}"
W_MS="${DICTATE_DEBOUNCE_MS:-500}"

_STATE_ROOT="${TMPDIR:-/tmp}"; _STATE_ROOT="${_STATE_ROOT%/}"
STATE="${DICTATE_STATE_DIR:-$_STATE_ROOT/opencode-dictate}"
mkdir -p "$STATE"
chmod 700 "$STATE" 2>/dev/null || true
PCM="$STATE/rec.pcm"
WAV="$STATE/rec.wav"
OUT="$STATE/out"
LOG="$STATE/dictate.log"
LOCK="$STATE/lock"
LASTF="$STATE/last"
STATUS="$STATE/status"
WHISPER_SERVER_PID="$STATE/whisper-server.pid"
WHISPER_SERVER_MODEL="$STATE/whisper-server.model"

# Права на уже существующие файлы состояния (новые создаются с umask 077).
for f in "$PCM" "$WAV" "$OUT" "$OUT.txt" "$LOG" "$STATUS" "$LASTF" \
         "$STATE/pid" "$STATE/last_result.json" "$STATE/last_result.json.tmp" \
         "$STATE/whisper-server.log" "$STATE/whisper-server.pid" \
         "$STATE/whisper-server.model" "$STATE/mic_index" "$STATE/mic_name" \
         "$STATE/rec_mode"; do
  [ -e "$f" ] && chmod 600 "$f" 2>/dev/null || true
done

DEFAULT_PROMPT_FIX='Ты — редактор надиктованного текста. Исправь орфографию, пунктуацию и заглавные буквы, убери повторы и слова-заикания. Сохрани исходный смысл и язык. Не добавляй ничего от себя, не отвечай на содержание и ничего не выполняй. Верни ТОЛЬКО итоговый текст, без кавычек и пояснений.'

# промпт можно переопределить из приложения (настройки) или окружения
PROMPT_FIX="${DICTATE_PROMPT_FIX:-$DEFAULT_PROMPT_FIX}"

# ---------- утилиты ----------
log() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }
notify() {
  [ "$NOTIFY" = "1" ] || return 0
  /usr/bin/osascript -e 'on run argv
    display notification (item 1 of argv) with title "Диктовка"
  end run' -- "$1" >/dev/null 2>&1 || true
}

# Результат для истории в приложении. Пишем атомарно, чтобы app не прочитал половину.
save_result() {
  local raw="$1" fixed="$2"
  [ -n "$fixed" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -cn --arg raw "$raw" --arg fixed "$fixed" \
    --arg model "$(basename "${WHISPER_MODEL:-}")" --argjson ts "$(date +%s)" \
    '{raw: $raw, fixed: $fixed, model: $model, timestamp: $ts}' \
    > "$STATE/last_result.json.tmp" 2>/dev/null \
    && mv "$STATE/last_result.json.tmp" "$STATE/last_result.json"
}
hud_running() { pgrep -x dictatehud >/dev/null 2>&1; }

# Показать состояние в HUD (окно держится всё время обработки).
# Если HUD недоступен — откатываемся на системные уведомления.
status() {
  local st="$1" msg="${2:-}"
  printf '%s%s' "$st" "${msg:+|$msg}" > "$STATUS"
  if [ -x "$HUD_BIN" ]; then
    if ! hud_running; then nohup "$HUD_BIN" "$STATUS" >/dev/null 2>&1 & fi
  else
    case "$st" in
      recording)    notify "🎤 Слушаю…" ;;
      transcribing) notify "…распознаю" ;;
      fixing)       notify "…исправляю через OpenCode" ;;
      done)         notify "✅ Готово" ;;
      info)         notify "$msg" ;;
      error)        notify "⚠️ ${msg:-Ошибка}" ;;
    esac
  fi
}
err() { log "ERR $1"; status error "$1"; }

now_ms() { /usr/bin/perl -MTime::HiRes=time -e 'print int(time()*1000)' 2>/dev/null; }

is_safe_exec() {
  local path="$1" mode tail
  [ -x "$path" ] || return 1
  mode="$(stat -f '%Lp' "$path" 2>/dev/null)" || return 1
  tail="${mode: -2}"
  [ $((8#$tail & 8#022)) -eq 0 ]
}

if [ -n "${OC_BIN:-}" ] && ! is_safe_exec "$OC_BIN"; then
  log "opencode: небезопасный OC_BIN — игнор"
  OC_BIN=""
fi
if [ -z "${OC_BIN:-}" ]; then
  for c in /opt/homebrew/bin/opencode \
           /usr/local/bin/opencode \
           "$(command -v opencode 2>/dev/null)" \
           "$HOME"/.npm/_npx/*/node_modules/.bin/opencode; do
    [ -n "$c" ] && is_safe_exec "$c" && { OC_BIN="$c"; break; }
  done
fi

# индекс микрофона кэшируем: `ffmpeg -list_devices` стоит ~0.4 с
MIC_CACHE="$STATE/mic_index"
MIC_CACHE_NAME="$STATE/mic_name"
mic_index() {
  if [ -n "${MIC_INDEX:-}" ]; then echo "$MIC_INDEX"; return; fi
  if [ -z "${MIC_NAME:-}" ]; then echo 0; return; fi
  if [ -s "$MIC_CACHE" ] && [ "$(cat "$MIC_CACHE_NAME" 2>/dev/null)" = "$MIC_NAME" ]; then
    cat "$MIC_CACHE"; return
  fi
  local i
  i="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
       | sed -n '/AVFoundation audio devices/,$p' \
       | grep -F "] $MIC_NAME" | head -1 \
       | grep -oE '\[[0-9]+\]' | tr -d '[]')"
  if [ -n "$i" ]; then
    printf '%s' "$i" > "$MIC_CACHE"
    printf '%s' "$MIC_NAME" > "$MIC_CACHE_NAME"
  fi
  echo "$i"
}

# ---- Whisper-server: модель держится в памяти (экономит ~0.5 с на запуск) ----
whisper_url() { echo "http://127.0.0.1:$WHISPER_SERVER_PORT"; }
whisper_up() { curl -s -o /dev/null --max-time 1 "$(whisper_url)/" 2>/dev/null; }
whisper_server_pid() { cat "$WHISPER_SERVER_PID" 2>/dev/null || true; }
whisper_server_matches() {
  [ -f "$WHISPER_SERVER_MODEL" ] && \
    [ "$(cat "$WHISPER_SERVER_MODEL" 2>/dev/null)" = "$WHISPER_MODEL|$WHISPER_SERVER_BIN" ]
}

whisper_stop_server() {
  local pid; pid="$(whisper_server_pid)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$WHISPER_SERVER_PID" "$WHISPER_SERVER_MODEL"
}

whisper_ensure() {
  # Если сервер уже стартует (pid есть, HTTP ещё не отвечает) — подождать его,
  # чтобы не запустить второй процесс на тот же порт.
  local starting; starting="$(whisper_server_pid)"
  if [ -n "$starting" ] && kill -0 "$starting" 2>/dev/null; then
    for _ in $(seq 1 80); do
      whisper_up && break
      kill -0 "$starting" 2>/dev/null || break
      sleep 0.25
    done
  fi

  if whisper_up; then
    if whisper_server_matches; then return 0; fi

    # Сервер мог быть запущен до появления маркера (или другим способом).
    # Если он уже использует нужную модель — просто запоминаем его pid.
    local running; running="$(/usr/sbin/lsof -ti "tcp:$WHISPER_SERVER_PORT" -sTCP:LISTEN 2>/dev/null | head -1)"
    if [ -n "$running" ]; then
      local cmd; cmd="$(ps -p "$running" -o command= 2>/dev/null || true)"
      if printf '%s' "$cmd" | grep -qF -- "$WHISPER_MODEL"; then
        printf '%s' "$running" > "$WHISPER_SERVER_PID"
        printf '%s|%s' "$WHISPER_MODEL" "$WHISPER_SERVER_BIN" > "$WHISPER_SERVER_MODEL"
        log "whisper: использую запущенный сервер pid=$running"
        return 0
      fi
    fi

    # Порт занят сервером с другой моделью. Свой процесс перезапускаем,
    # чужой (например, старый LaunchAgent) не трогаем — уходим в whisper-cli.
    if [ -n "$(whisper_server_pid)" ]; then
      log "whisper: модель изменилась — перезапускаю сервер"
      whisper_stop_server
      sleep 0.2
    fi
    if whisper_up; then
      log "whisper: порт $WHISPER_SERVER_PORT занят другим сервером — whisper-cli"
      return 1
    fi
  fi

  if [ ! -x "$WHISPER_SERVER_BIN" ] && ! command -v "$WHISPER_SERVER_BIN" >/dev/null 2>&1; then
    return 1
  fi

  local vad=(); [ -f "$WHISPER_VAD_MODEL" ] && vad=(--vad -vm "$WHISPER_VAD_MODEL")
  nohup "$WHISPER_SERVER_BIN" -m "$WHISPER_MODEL" "${vad[@]}" \
    --host 127.0.0.1 --port "$WHISPER_SERVER_PORT" -t "$WHISPER_THREADS" \
    >>"$STATE/whisper-server.log" 2>&1 &
  local pid=$!
  printf '%s' "$pid" > "$WHISPER_SERVER_PID"
  printf '%s|%s' "$WHISPER_MODEL" "$WHISPER_SERVER_BIN" > "$WHISPER_SERVER_MODEL"
  for _ in $(seq 1 160); do
    whisper_up && return 0
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  whisper_stop_server
  return 1
}

# transcribe <wav> -> текст в stdout
transcribe() {
  local wav="$1"
  if whisper_ensure; then
    log "transcribe: whisper-server model=$(basename "$WHISPER_MODEL")"
    curl -s --max-time 300 -F "file=@$wav" -F "language=$WHISPER_LANG" -F "response_format=json" \
      "$(whisper_url)/inference" 2>/dev/null | jq -r '.text // empty'
    return
  fi
  log "transcribe: whisper-cli (сервер недоступен)"
  local v=(); [ -f "$WHISPER_VAD_MODEL" ] && v=(--vad -vm "$WHISPER_VAD_MODEL")
  "$WHISPER_CLI_BIN" -m "$WHISPER_MODEL" "${v[@]}" -l "$WHISPER_LANG" -t "$WHISPER_THREADS" \
    -nt -otxt -of "$OUT" "$wav" >/dev/null 2>&1
  cat "$OUT.txt" 2>/dev/null
}

recording() { pgrep -f "$PCM" >/dev/null 2>&1; }

stop_recorders() {
  local pids
  pids="$(pgrep -f "$PCM" 2>/dev/null)"; [ -z "$pids" ] && return 0
  kill -INT $pids 2>/dev/null
  for _ in $(seq 1 10); do recording || return 0; sleep 0.1; done
  pids="$(pgrep -f "$PCM" 2>/dev/null)"; [ -n "$pids" ] && kill -TERM $pids 2>/dev/null
  sleep 0.3
  pids="$(pgrep -f "$PCM" 2>/dev/null)"; [ -n "$pids" ] && kill -KILL $pids 2>/dev/null
  sleep 0.2
  return 0
}

paste_text() {
  local out rc
  if [ -x "$SCRIPT_DIR/pastev" ]; then
    out="$("$SCRIPT_DIR/pastev" 2>&1)"; rc=$?
    log "paste: pastev rc=$rc ${out:+msg=$out}"
    [ "$rc" = "0" ] && return 0
  fi
  if command -v cliclick >/dev/null 2>&1; then
    out="$(cliclick kd:cmd t:v ku:cmd 2>&1)"; rc=$?
    log "paste: cliclick rc=$rc ${out:+msg=$out}"
    [ "$rc" = "0" ] && [ -z "$out" ] && return 0
  fi
  out="$(osascript -e 'tell application "System Events" to key code 9 using command down' 2>&1)"; rc=$?
  log "paste: osascript(fallback) rc=$rc ${out:+msg=$out}"
}

# Разрешён только HTTPS или HTTP на loopback (для локальных API).
safe_ai_url() {
  local url="$1"
  case "$url" in
    *$'\n'*|*$'\r'*|*[[:space:]]*|*@*|*\?*|*\#*) return 1 ;;
  esac
  case "$url" in
    https://*) return 0 ;;
    http://localhost|http://localhost/*|http://localhost:*|http://127.0.0.1|http://127.0.0.1/*|http://127.0.0.1:*|http://\[::1\]|http://\[::1\]/*|http://\[::1\]:*) return 0 ;;
  esac
  return 1
}

# generate_fix <raw> -> исправленный текст в stdout.
# Тип AI задаётся DICTATE_AI_KIND: openai | anthropic | opencode.
generate_fix() {
  local raw="$1"
  local sys="$PROMPT_FIX"
  local kind="${DICTATE_AI_KIND:-}"

  if [ -z "$kind" ]; then
    if [ -n "${OC_BASE_URL:-}" ]; then kind=openai; else kind=opencode; fi
  fi

  if [ "${DICTATE_USE_OC:-1}" = "0" ]; then
    log "generate: AI отключён — RAW"
    printf '%s' "$raw"
    return 0
  fi

  case "$kind" in
    anthropic)
      if [ -z "${OC_BASE_URL:-}" ] || ! safe_ai_url "$OC_BASE_URL"; then
        log "generate: anthropic без безопасного base URL — RAW"
        printf '%s' "$raw"
        return 0
      fi
      local akey="${OC_API_KEY:-}"
      akey="${akey//$'\r'/}"
      akey="${akey//$'\n'/}"
      local abase="${OC_BASE_URL%/}"
      local aurl
      case "$abase" in
        */v1/messages) aurl="$abase" ;;
        */messages) aurl="$abase" ;;
        */v1) aurl="$abase/messages" ;;
        *) aurl="$abase/v1/messages" ;;
      esac
      local apayload
      apayload="$(jq -cn --arg model "$OC_MODEL_ID" --arg sys "$sys" --arg raw "$raw" \
        '{model: $model, max_tokens: 4096, temperature: 0, system: $sys,
          messages: [{role: "user", content: ("<text>" + $raw + "</text>")}]}')"
      log "generate: anthropic $aurl model=$OC_MODEL_ID"
      if [ -n "$akey" ]; then
        curl -s --max-time 120 -H 'Content-Type: application/json' \
          -H "x-api-key: $akey" -H 'anthropic-version: 2023-06-01' \
          -d "$apayload" -- "$aurl" 2>>"$LOG" \
          | jq -r '[.content[]? | select(.type == "text") | .text] | join("")' 2>>"$LOG"
      else
        curl -s --max-time 120 -H 'Content-Type: application/json' \
          -H 'anthropic-version: 2023-06-01' \
          -d "$apayload" -- "$aurl" 2>>"$LOG" \
          | jq -r '[.content[]? | select(.type == "text") | .text] | join("")' 2>>"$LOG"
      fi
      ;;

    openai)
      if [ -z "${OC_BASE_URL:-}" ] || ! safe_ai_url "$OC_BASE_URL"; then
        log "generate: openai без безопасного base URL — RAW"
        printf '%s' "$raw"
        return 0
      fi
      local okey="${OC_API_KEY:-}"
      okey="${okey//$'\r'/}"
      okey="${okey//$'\n'/}"
      local ourl
      case "$OC_BASE_URL" in
        */chat/completions) ourl="$OC_BASE_URL" ;;
        *) ourl="${OC_BASE_URL%/}/chat/completions" ;;
      esac
      local opayload
      opayload="$(jq -cn --arg model "$OC_MODEL_ID" --arg sys "$sys" --arg raw "$raw" \
        '{model: $model, temperature: 0, messages: [{role: "system", content: $sys}, {role: "user", content: ("<text>" + $raw + "</text>")}]}')"
      log "generate: openai $ourl model=$OC_MODEL_ID"
      if [ -n "$okey" ]; then
        curl -s --max-time 120 -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $okey" -d "$opayload" -- "$ourl" 2>>"$LOG" \
          | jq -r '.choices[0].message.content // empty' 2>>"$LOG"
      else
        curl -s --max-time 120 -H 'Content-Type: application/json' \
          -d "$opayload" -- "$ourl" 2>>"$LOG" \
          | jq -r '.choices[0].message.content // empty' 2>>"$LOG"
      fi
      ;;

    *)
      local body
      body="$(jq -cn --arg sys "$sys" --arg raw "$raw" --arg prov "$OC_PROVIDER" --arg id "$OC_MODEL_ID" --arg var "$OC_VARIANT" \
        '{prompt: ($sys + "\n\n<text>" + $raw + "</text>"), model: ({providerID: $prov, id: $id} + (if $var == "" then {} else {variant: $var} end))}')"
      log "generate: opencode provider=$OC_PROVIDER model=$OC_MODEL_ID"
      "${OC_BIN:-opencode}" api post /api/experimental/generate --data "$body" 2>>"$LOG" \
        | jq -r '.data.text // empty' 2>>"$LOG"
      ;;
  esac
}

start_recording() {
  if recording; then log "start: уже идёт — игнор"; return 0; fi
  if [ ! -f "$WHISPER_MODEL" ]; then
    log "model: не найдена: $WHISPER_MODEL"
    err "модель Whisper не найдена — выберите её в настройках"
    return 1
  fi
  local idx; idx="$(mic_index)"
  if [ -z "$idx" ]; then
    err "микрофон не найден: ${MIC_NAME:-устройство по умолчанию}"
    return 1
  fi
  rm -f "$PCM" "$WAV" "$OUT.txt" "$STATE/last_result.json" "$STATE/last_result.json.tmp"
  status preparing
  ffmpeg -hide_banner -loglevel error -nostdin -f avfoundation -i ":$idx" \
    -ar 16000 -ac 1 -c:a pcm_s16le -f s16le -y "$PCM" >>"$LOG" 2>&1 &
  echo $! > "$STATE/pid"
  sleep 0.2
  if ! recording; then
    rm -f "$STATE/pid" "$MIC_CACHE"
    err "не удалось начать запись (микрофон/права)"; return 1
  fi
  log "start: mic=$idx pid=$(cat "$STATE/pid" 2>/dev/null)"
  status recording
}

stop_and_insert() {
  if ! recording; then log "stop: запись не идёт"; status info "запись не идёт"; return 0; fi
  if [ ! -f "$WHISPER_MODEL" ]; then
    stop_recorders; rm -f "$STATE/pid"
    log "model: не найдена: $WHISPER_MODEL"
    err "модель Whisper не найдена — выберите её в настройках"
    return 1
  fi
  stop_recorders; rm -f "$STATE/pid"
  status transcribing

  local sz; sz=$(stat -f%z "$PCM" 2>/dev/null || echo 0)
  log "stop: pcm_bytes=$sz"
  if [ "${sz:-0}" -lt 6400 ]; then err "запись слишком короткая или пустая"; return 1; fi

  # один вызов ffmpeg: и WAV, и замер громкости
  local vol
  vol="$(ffmpeg -hide_banner -y -f s16le -ar 16000 -ac 1 -i "$PCM" \
        -c:a pcm_s16le "$WAV" -af volumedetect -f null - 2>&1 \
        | sed -n 's/.*max_volume: \([^ ]*\) dB.*/\1/p')"
  [ -s "$WAV" ] || { err "не удалось собрать WAV"; return 1; }
  log "max_volume=${vol:-?} dB"

  local raw; raw="$(transcribe "$WAV")"
  raw="$(printf '%s' "$raw" | tr '\n' ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  log "RAW: $raw"
  [ -z "$raw" ] && { err "речь не распознана (тишина?)"; return 1; }

  status fixing
  local fixed ai_start ai_elapsed
  ai_start="$(now_ms)"
  fixed="$(generate_fix "$raw")"
  ai_elapsed=$(( $(now_ms) - ai_start ))
  if [ "${DICTATE_USE_OC:-1}" = "0" ]; then
    log "generate: AI disabled"
  else
    log "generate: AI response ${ai_elapsed}ms kind=${DICTATE_AI_KIND:-auto} model=${OC_MODEL_ID:-?}"
  fi
  if [ -z "$fixed" ]; then
    log "generate: пустой ответ — подставляю RAW"
    fixed="$raw"
  fi
  log "FIXED: $fixed"

  if [ "$DRY_RUN" = "1" ]; then printf 'RAW:   %s\nFIXED: %s\n' "$raw" "$fixed"; status info "dry run"; return 0; fi

  local old=""; [ "$RESTORE_CLIPBOARD" = "1" ] && old="$(pbpaste 2>/dev/null || true)"
  printf '%s' "$fixed" | pbcopy
  save_result "$raw" "$fixed"

  # В режиме приложения ⌘V отправляет само приложение (у него есть Accessibility).
  if [ "${DICTATE_NO_PASTE:-0}" = "1" ]; then
    log "paste: delegated to app"
    status done
    return 0
  fi

  sleep 0.15
  paste_text
  sleep 0.5
  [ "$RESTORE_CLIPBOARD" = "1" ] && printf '%s' "$old" | pbcopy
  status done
}

# Отмена записи: остановить ffmpeg, удалить звук и не запускать распознавание/AI.
cancel_recording() {
  if ! recording; then
    log "cancel: запись не идёт"
    return 0
  fi
  stop_recorders
  rm -f "$STATE/pid" "$PCM" "$WAV" "$OUT" "$OUT.txt" \
        "$STATE/last_result.json" "$STATE/last_result.json.tmp" "$LASTF"
  log "cancel: запись отменена"
  status info "Запись отменена"
}

# =========================================================
# 0) отмена записи — до debounce/lock, чтобы кнопка срабатывала сразу.
if [ "$ACTION" = "cancel" ]; then
  cancel_recording
  exit 0
fi

# 0) тест микрофона: 1 секунда записи, печатает index/level.
if [ "$ACTION" = "mic-test" ]; then
  if [ -d "$LOCK" ]; then echo "error=busy"; exit 0; fi
  idx="$(mic_index)"
  if [ -z "$idx" ]; then echo "error=notfound"; exit 0; fi
  out="$(ffmpeg -hide_banner -f avfoundation -i ":$idx" -t 1 -af volumedetect -f null - 2>&1)"
  level="$(printf '%s' "$out" | sed -n 's/.*max_volume: \([^ ]*\) dB.*/\1/p' | tail -1)"
  echo "index=$idx"
  echo "level=${level:-unknown}"
  exit 0
fi

# =========================================================
# 0) прогрев сервера после сохранения настроек.
# Не трогает запись, статус, HUD и буфер обмена.
if [ "$ACTION" = "warmup" ]; then
  if [ ! -f "$WHISPER_MODEL" ]; then
    log "warmup: модель не найдена: $WHISPER_MODEL"
    exit 0
  fi
  if [ -d "$LOCK" ]; then
    log "warmup: идёт диктовка — пропуск"
    exit 0
  fi
  WARM_LOCK="$STATE/warmup.lock"
  if ! mkdir "$WARM_LOCK" 2>/dev/null; then
    wp="$(cat "$WARM_LOCK/pid" 2>/dev/null || true)"
    if [ -n "$wp" ] && kill -0 "$wp" 2>/dev/null; then exit 0; fi
    rm -rf "$WARM_LOCK"; mkdir "$WARM_LOCK" 2>/dev/null || exit 0
  fi
  echo $$ > "$WARM_LOCK/pid"
  trap 'rm -rf "$WARM_LOCK"' EXIT
  log "warmup: $WHISPER_MODEL"
  if whisper_ensure; then
    log "warmup: готов"
  else
    log "warmup: не удалось запустить сервер"
  fi
  exit 0
fi

# =========================================================
# 1) подавление авто-повтора: обновляем метку на КАЖДОМ вызове
NOW="$(now_ms)"
LAST="$(cat "$LASTF" 2>/dev/null || echo 0)"
echo "${NOW:-0}" > "$LASTF"
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
if [ -n "$NOW" ] && [ $((NOW - LAST)) -lt "$W_MS" ]; then exit 0; fi

# 2) сериализация: не даём одновременным вызовам пересечься
if ! mkdir "$LOCK" 2>/dev/null; then
  lp="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; then exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# 3) действие
case "$ACTION" in
  start)  start_recording ;;
  stop)   stop_and_insert ;;
  toggle) if recording; then stop_and_insert; else start_recording; fi ;;
  *) echo "usage: dictate.sh [toggle|start|stop|cancel]" >&2; exit 2 ;;
esac
