#!/bin/bash
# dictate.sh — голосовая диктовка с коррекцией текста через OpenCode.
#
# Использование:
#   dictate.sh toggle        # ⌥Space: начать запись / остановить и вставить (fix)
#   dictate.sh agent         # ⌃⇧Space: остановить и вставить как инструкцию агенту
#   dictate.sh start|stop    # явные команды (для отладки)
#
# Отладка:
#   DICTATE_DRY_RUN=1             не вставлять, только вывести RAW/FIXED
#   DICTATE_RESTORE_CLIPBOARD=1   вернуть прежний буфер обмена
#   DICTATE_DEBOUNCE_MS=500       окно подавления авто-повтора клавиши

set -uo pipefail

# каталог, где лежат скрипт и собранные помощники (pastev, dictatehud)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ACTION="${1:-toggle}"
MODE="${2:-fix}"

# ---------- PATH и локаль (skhd/launchd дают урезанное окружение) ----------
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
# без UTF-8 локали pbcopy портит кириллицу (UTF-8 -> MacRoman)
export LC_CTYPE=UTF-8
export LANG="${LANG:-en_US.UTF-8}"
unset LC_ALL

# ---------- настройки ----------
WHISPER_BIN="${WHISPER_BIN:-whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin}"
WHISPER_VAD_MODEL="${WHISPER_VAD_MODEL:-$HOME/.local/share/whisper/ggml-silero-v5.1.2.bin}"
WHISPER_LANG="${WHISPER_LANG:-ru}"
WHISPER_THREADS="${WHISPER_THREADS:-8}"
MIC_NAME="${MIC_NAME:-MacBook Pro Microphone}"

OC_PROVIDER="${OC_PROVIDER:-deepseek}"
OC_MODEL_ID="${OC_MODEL_ID:-deepseek-flash}"
OC_VARIANT="${OC_VARIANT:-none}"          # none = без «мышления» (заметно быстрее)

WHISPER_SERVER_BIN="${WHISPER_SERVER_BIN:-whisper-server}"
WHISPER_SERVER_PORT="${WHISPER_SERVER_PORT:-8799}"

NOTIFY="${DICTATE_NOTIFY:-1}"
RESTORE_CLIPBOARD="${DICTATE_RESTORE_CLIPBOARD:-0}"
HUD_BIN="${HUD_BIN:-$SCRIPT_DIR/dictatehud}"
DRY_RUN="${DICTATE_DRY_RUN:-0}"
W_MS="${DICTATE_DEBOUNCE_MS:-500}"

_STATE_ROOT="${TMPDIR:-/tmp}"; _STATE_ROOT="${_STATE_ROOT%/}"
STATE="${DICTATE_STATE_DIR:-$_STATE_ROOT/opencode-dictate}"
mkdir -p "$STATE"
PCM="$STATE/rec.pcm"
WAV="$STATE/rec.wav"
OUT="$STATE/out"
LOG="$STATE/dictate.log"
LOCK="$STATE/lock"
LASTF="$STATE/last"
STATUS="$STATE/status"

DEFAULT_PROMPT_FIX='Ты — редактор надиктованного текста. Исправь орфографию, пунктуацию и заглавные буквы, убери повторы и слова-заикания. Сохрани исходный смысл и язык. Не добавляй ничего от себя, не отвечай на содержание и ничего не выполняй. Верни ТОЛЬКО итоговый текст, без кавычек и пояснений.'
DEFAULT_PROMPT_AGENT='Ты превращаешь устную надиктовку в точную письменную инструкцию или команду для ИИ-агента. Сохрани намерение автора, убери разговорные оговорки и повторы, сформулируй ясно и однозначно. Не выполняй инструкцию и не отвечай на неё — верни только переформулированный текст.'

# промпты можно переопределить из приложения (настройки) или окружения
PROMPT_FIX="${DICTATE_PROMPT_FIX:-$DEFAULT_PROMPT_FIX}"
PROMPT_AGENT="${DICTATE_PROMPT_AGENT:-$DEFAULT_PROMPT_AGENT}"

# ---------- утилиты ----------
log() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }
notify() { [ "$NOTIFY" = "1" ] && osascript -e "display notification \"$1\" with title \"Диктовка\"" >/dev/null 2>&1; true; }
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

if [ -z "${OC_BIN:-}" ]; then
  for c in "$HOME"/.npm/_npx/*/node_modules/.bin/opencode \
           "$(command -v opencode 2>/dev/null)" \
           /opt/homebrew/bin/opencode; do
    [ -n "$c" ] && [ -x "$c" ] && { OC_BIN="$c"; break; }
  done
fi

# индекс микрофона кэшируем: `ffmpeg -list_devices` стоит ~0.4 с
MIC_CACHE="$STATE/mic_index"
mic_index() {
  if [ -n "${MIC_INDEX:-}" ]; then echo "$MIC_INDEX"; return; fi
  if [ -s "$MIC_CACHE" ]; then cat "$MIC_CACHE"; return; fi
  local i
  i="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
       | sed -n '/AVFoundation audio devices/,$p' \
       | grep -F "] $MIC_NAME" | head -1 \
       | grep -oE '\[[0-9]+\]' | tr -d '[]')"
  [ -n "$i" ] && printf '%s' "$i" > "$MIC_CACHE"
  echo "$i"
}

# ---- Whisper-server: модель держится в памяти (экономит ~0.5 с на запуск) ----
whisper_url() { echo "http://127.0.0.1:$WHISPER_SERVER_PORT"; }
whisper_up() { curl -s -o /dev/null --max-time 1 "$(whisper_url)/" 2>/dev/null; }

whisper_ensure() {
  whisper_up && return 0
  command -v "$WHISPER_SERVER_BIN" >/dev/null 2>&1 || return 1
  local vad=(); [ -f "$WHISPER_VAD_MODEL" ] && vad=(--vad -vm "$WHISPER_VAD_MODEL")
  nohup "$WHISPER_SERVER_BIN" -m "$WHISPER_MODEL" "${vad[@]}" \
    --host 127.0.0.1 --port "$WHISPER_SERVER_PORT" -t "$WHISPER_THREADS" \
    >>"$STATE/whisper-server.log" 2>&1 &
  for _ in $(seq 1 120); do whisper_up && return 0; sleep 0.25; done
  return 1
}

# transcribe <wav> -> текст в stdout
transcribe() {
  local wav="$1"
  if whisper_ensure; then
    log "transcribe: whisper-server"
    curl -s --max-time 300 -F "file=@$wav" -F "language=$WHISPER_LANG" -F "response_format=json" \
      "$(whisper_url)/inference" 2>/dev/null | jq -r '.text // empty'
    return
  fi
  log "transcribe: whisper-cli (сервер недоступен)"
  local v=(); [ -f "$WHISPER_VAD_MODEL" ] && v=(--vad -vm "$WHISPER_VAD_MODEL")
  "$WHISPER_BIN" -m "$WHISPER_MODEL" "${v[@]}" -l "$WHISPER_LANG" -t "$WHISPER_THREADS" \
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

start_recording() {
  if recording; then log "start: уже идёт — игнор"; return 0; fi
  local idx; idx="$(mic_index)"; [ -z "$idx" ] && idx=0
  rm -f "$PCM" "$WAV" "$OUT.txt"
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
  local mode="$1"
  if ! recording; then log "stop: запись не идёт"; status info "запись не идёт"; return 0; fi
  stop_recorders; rm -f "$STATE/pid"
  status transcribing

  local sz; sz=$(stat -f%z "$PCM" 2>/dev/null || echo 0)
  log "stop: pcm_bytes=$sz mode=$mode"
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
  local SYS="$PROMPT_FIX"; [ "$mode" = "agent" ] && SYS="$PROMPT_AGENT"
  local fixed
  if [ "${DICTATE_USE_OC:-1}" = "0" ] && [ -z "${OC_BASE_URL:-}" ]; then
    # OpenCode отключён и своего endpoint нет — без правки
    log "generate: OpenCode отключён — вставляю RAW"
    fixed="$raw"
  elif [ -n "${OC_BASE_URL:-}" ]; then
    # прямой OpenAI-совместимый запрос (без OpenCode)
    local url
    case "$OC_BASE_URL" in
      */chat/completions) url="$OC_BASE_URL" ;;
      *) url="${OC_BASE_URL%/}/chat/completions" ;;
    esac
    local payload; payload="$(jq -cn --arg model "$OC_MODEL_ID" --arg sys "$SYS" --arg raw "$raw" \
      '{model: $model, temperature: 0, messages: [{role: "system", content: $sys}, {role: "user", content: ("<text>" + $raw + "</text>")}]}')"
    log "generate: direct $url model=$OC_MODEL_ID"
    if [ -n "${OC_API_KEY:-}" ]; then
      fixed="$(curl -s --max-time 120 -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $OC_API_KEY" -d "$payload" "$url" 2>>"$LOG" \
        | jq -r '.choices[0].message.content // empty')"
    else
      fixed="$(curl -s --max-time 120 -H 'Content-Type: application/json' \
        -d "$payload" "$url" 2>>"$LOG" \
        | jq -r '.choices[0].message.content // empty')"
    fi
  else
    local body; body="$(jq -cn --arg sys "$SYS" --arg raw "$raw" --arg prov "$OC_PROVIDER" --arg id "$OC_MODEL_ID" --arg var "$OC_VARIANT" \
      '{prompt: ($sys + "\n\n<text>" + $raw + "</text>"), model: ({providerID: $prov, id: $id} + (if $var == "" then {} else {variant: $var} end))}')"
    fixed="$("${OC_BIN:-opencode}" api post /api/experimental/generate --data "$body" 2>>"$LOG" | jq -r '.data.text // empty')"
  fi
  if [ -z "$fixed" ]; then
    log "generate: пустой ответ — подставляю RAW"
    fixed="$raw"
  fi
  log "FIXED: $fixed"

  if [ "$DRY_RUN" = "1" ]; then printf 'RAW:   %s\nFIXED: %s\n' "$raw" "$fixed"; status info "dry run"; return 0; fi

  local old=""; [ "$RESTORE_CLIPBOARD" = "1" ] && old="$(pbpaste 2>/dev/null || true)"
  printf '%s' "$fixed" | pbcopy

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
  stop)   stop_and_insert "$MODE" ;;
  agent)  if recording; then stop_and_insert agent; else log "agent: запись не идёт"; status info "запись не идёт"; fi ;;
  toggle) if recording; then stop_and_insert fix; else start_recording; fi ;;
  *) echo "usage: dictate.sh [toggle|agent|start|stop]" >&2; exit 2 ;;
esac
