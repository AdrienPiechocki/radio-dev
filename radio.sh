#!/usr/bin/env bash
# =============================================================================
# radio.sh — FIFO permanent vers Icecast, écriture non-bloquante via fd dédié
# =============================================================================

set -euo pipefail
export TZ="Europe/Paris"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PLAYLIST_POS=0

STATUS_JSON="./status${ICECAST_MOUNT//\//-}.json"
COVER_ART="./web/cover${ICECAST_MOUNT//\//-}.jpg"
SCHEDULE_JSON="./schedule.json"
LAST_EVENT_FILE="./.last_event${ICECAST_MOUNT//\//-}"

PODCAST_GEN="./podcast-generator/run.sh"
PLAYLIST="./playlist${ICECAST_MOUNT//\//-}.m3u"
NEWS_WAV="./radio-generator/news.wav"
WEATHER_WAV="./radio-generator/weather.wav"
RADIO_GEN="./radio-generator/run.sh"

ICECAST_HOST="${ICECAST_HOST:-icecast}"
ICECAST_PORT="${ICECAST_PORT:-8000}"
ICECAST_SOURCE_PASSWORD="${ICECAST_SOURCE_PASSWORD:-hackme}"
ICECAST_MOUNT="${ICECAST_MOUNT:-/radio}"

RADIO_ROLE="${RADIO_ROLE:-local}"

GEN_PID=""
FFMPEG_PID=""
FIFO="/tmp/radio_pipe"
# fd 3 est ouvert en écriture sur le FIFO — maintenu ouvert en permanence
# pour éviter que le streamer ffmpeg reçoive EOF entre deux morceaux.
FIFO_FD=3

log() { echo "[$(date '+%H:%M:%S %Z')] $*"; }

# =============================================================================
# FIFO / STREAMER
# =============================================================================

start_streamer() {
    rm -f "$FIFO"
    mkfifo "$FIFO"

    # Ouvre le fd 3 en écriture sur le FIFO (non-bloquant côté open grâce au
    # fait que ffmpeg ouvre le FIFO en lecture juste après).
    # On lance ffmpeg d'abord en arrière-plan, puis on ouvre le fd.
    ffmpeg \
        -hide_banner -nostdin \
        -re \
        -f s16le -ar 44100 -ac 2 -channel_layout stereo \
        -i "$FIFO" \
        -codec:a libmp3lame -b:a 128k -ar 44100 \
        -ice_name "Radio Locale" \
        -ice_description "Ma radio IA" \
        -content_type audio/mpeg \
        -f mp3 \
        "icecast://source:${ICECAST_SOURCE_PASSWORD}@${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT}" \
        -loglevel error &
    FFMPEG_PID=$!

    # Ouvre fd 3 en écriture avec timeout — si ffmpeg plante avant d'ouvrir le FIFO
    # en lecture, on ne bloque pas indéfiniment (ce qui causait les restarts en boucle).
    local waited=0
    while true; do
        # Tente l'ouverture en non-bloquant via sous-shell
        if ( exec 3>"$FIFO" ) 2>/dev/null; then
            exec 3>"$FIFO"
            break
        fi
        # Vérifie que ffmpeg est toujours vivant
        if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
            log "❌  ffmpeg mort avant ouverture du FIFO — abandon"
            return 1
        fi
        (( waited++ ))
        if [[ $waited -ge 20 ]]; then
            log "❌  Timeout ouverture FIFO après ${waited}s — ffmpeg ne répond pas"
            kill "$FFMPEG_PID" 2>/dev/null || true
            return 1
        fi
        sleep 0.5
    done

    log "🔌  Streamer démarré (PID $FFMPEG_PID)"
}

check_streamer() {
    if [[ -n "${FFMPEG_PID:-}" ]] && ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log "⚠️  Streamer mort, redémarrage..."
        exec 3>&-   # ferme l'ancien fd
        start_streamer
    fi
}

# Envoie un fichier audio dans le FIFO via fd 3
# ffmpeg décode en PCM s16le 44100 stéréo et écrit dans le fd ouvert
stream_to_fifo() {
    local file="$1"
    local gain="${2:-}"
    local af_opts=()
    [[ -n "$gain" ]] && af_opts=(-af "volume=${gain}")
    ffmpeg -hide_banner -nostdin \
        -i "$file" \
        -vn \
        -map 0:a:0 \
        "${af_opts[@]}" \
        -f s16le -ar 44100 -ac 2 \
        -loglevel error \
        - 2> >(grep -v "Invalid PNG signature" >&2) >&3
}

update_icecast_metadata() {
    local title="$1"
    local artist="$2"
    local album="$3"
    local song="$title"
    [ -n "$artist" ] && song="$song - $artist"
    [ -n "$album" ] && song="$song - $album"
    local i
    for i in $(seq 1 10); do
        local response
        response=$(curl -s \
            "http://${ICECAST_HOST}:${ICECAST_PORT}/admin/metadata" \
            --user "admin:${ICECAST_ADMIN_PASSWORD:-admin}" \
            --get \
            --data-urlencode "mount=${ICECAST_MOUNT}" \
            --data-urlencode "mode=updinfo" \
            --data-urlencode "charset=UTF-8" \
            --data-urlencode "song=${song}")
        if echo "$response" | grep -q "Metadata update successful"; then
            return 0
        fi
        sleep 2
    done
    log "WARN : metadata Icecast non envoyée après 10 tentatives"
}

# =============================================================================
# SCHEDULING
# =============================================================================

read_last_event()  { [[ -f "$LAST_EVENT_FILE" ]] && cat "$LAST_EVENT_FILE" || echo ""; }
write_last_event() { echo "$(date '+%Y-%m-%d %H:%M')-${1}" > "$LAST_EVENT_FILE"; }

get_next_future_event() {
    local grace="${1:-0}"
    [[ -f "$SCHEDULE_JSON" ]] || return 0
    python3 -c "
import json, datetime, sys
with open('$SCHEDULE_JSON') as f:
    schedule = json.load(f)
now = datetime.datetime.now()
now_min = now.hour * 60 + now.minute + now.second / 60
grace_min = float($grace) / 60.0

events = []
for time_str, etype in schedule.items():
    h, m = map(int, time_str.split(':'))
    events.append((h * 60 + m, f'{h:02d}:{m:02d}', etype))
events.sort()

# On ne cherche QUE les événements restant AUJOURD'HUI
for total, hhmm, etype in events:
    if total > (now_min + grace_min):
        print(f'{hhmm}:{etype}')
        sys.exit(0)
# Si on arrive ici, il n'y a plus rien aujourd'hui. 
# On ne renvoie RIEN pour éviter la boucle sur le lendemain.
" 2>/dev/null || true
}

get_missed_events() {
    local last_id
    last_id=$(read_last_event)
    [[ -f "$SCHEDULE_JSON" ]] || return 0
    python3 -c "
import json, datetime, sys, re
with open('$SCHEDULE_JSON') as f:
    schedule = json.load(f)
now = datetime.datetime.now()
now_min = now.hour * 60 + now.minute + now.second / 60
today = now.strftime('%Y-%m-%d')
raw = '$last_id'
m = re.match(r'^(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}-(.+)$', raw)
last_date = m.group(1) if m else ''
last_id   = m.group(2) if m else ''
events = []
for time_str, etype in schedule.items():
    parts = time_str.strip().split(':')
    if len(parts) != 2: continue
    h, m2 = int(parts[0]), int(parts[1])
    events.append((h * 60 + m2, f'{h:02d}:{m2:02d}', etype))
events.sort()
if last_date < today:
    missed = [(hhmm, etype) for total, hhmm, etype in events if total <= now_min]
elif last_id == '':
    missed = [(hhmm, etype) for total, hhmm, etype in events if total <= now_min][-1:]
else:
    missed = []
    found = False
    for total, hhmm, etype in events:
        if total > now_min:
            break
        if f'{hhmm}-{etype}' == last_id:
            found = True
            missed = []
        elif found:
            missed.append((hhmm, etype))
for hhmm, etype in missed:
    print(f'{hhmm}:{etype}')
" 2>/dev/null || true
}

get_next_event_time() {
    [[ -f "$SCHEDULE_JSON" ]] || return 0
    python3 -c "
import json, datetime, sys
with open('$SCHEDULE_JSON') as f:
    schedule = json.load(f)
now = datetime.datetime.now()
now_min = now.hour * 60 + now.minute + now.second / 60
events = []
for time_str, etype in schedule.items():
    parts = time_str.strip().split(':')
    if len(parts) != 2: continue
    h, m = int(parts[0]), int(parts[1])
    events.append((h * 60 + m, f'{h:02d}:{m:02d}', etype))
events.sort()
for total, hhmm, etype in events:
    if total > now_min:
        print(f'WAIT:{hhmm}:{etype}')
        sys.exit(0)
if events:
    _, hhmm, etype = events[0]
    print(f'WAIT:{hhmm}:{etype}')
" 2>/dev/null || true
}

get_pending_event() {
    local last_id
    last_id=$(read_last_event)
    [[ -f "$SCHEDULE_JSON" ]] || return 0
    python3 -c "
import json, datetime, sys, re
with open('$SCHEDULE_JSON') as f:
    schedule = json.load(f)
now = datetime.datetime.now()
now_min = now.hour * 60 + now.minute + now.second / 60
today = now.strftime('%Y-%m-%d')
raw = '$last_id'
m = re.match(r'^(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}-(.+)$', raw)
last_date = m.group(1) if m else ''
last_id   = m.group(2) if m else ''
if last_id == '' or last_date < today:
    sys.exit(0)
events = []
for time_str, etype in schedule.items():
    parts = time_str.strip().split(':')
    if len(parts) != 2: continue
    h, m2 = int(parts[0]), int(parts[1])
    events.append((h * 60 + m2, f'{h:02d}:{m2:02d}', etype))
events.sort()
last_idx = -1
for i, (total, hhmm, etype) in enumerate(events):
    if f'{hhmm}-{etype}' == last_id:
        last_idx = i
        break
for i, (total, hhmm, etype) in enumerate(events):
    if i <= last_idx:
        continue
    if total <= now_min:
        print(f'{hhmm}:{etype}')
        sys.exit(0)
" 2>/dev/null || true
}

seconds_until() {
    local hhmm="$1"
    python3 - <<EOF
from datetime import datetime
now = datetime.now()
try:
    h, m = map(int, "$hhmm".split(":"))
    target = now.replace(hour=h, minute=m, second=0, microsecond=0)
    diff = (target - now).total_seconds()
    # On ne renvoie le délai que si l'évènement est dans le futur MAIS aujourd'hui
    # Si diff < 0, l'heure est passée.
    print(int(diff))
except Exception:
    print(-1)
EOF
}

dispatch_event() {
    local event_type="$1"
    local event_id="$2"
    log "📅  Event schedulé : $event_type (id=$event_id)"

    case "$event_type" in
        gen_podcast)
            write_last_event "$event_id"
            if [[ "$RADIO_ROLE" == "local" ]]; then
                generate_podcast &
                GEN_PID=$!
                wait_for_generation_with_music "gen_podcast"
            else
                log "⏭️  Génération podcast ignorée (rôle: $RADIO_ROLE)"
            fi
            ;;
        run_podcast)
            write_last_event "$event_id"
            LOCAL_PODCAST=$(ls -t ./podcasts/podcast_*.wav 2>/dev/null \
                | grep -v '\.played' | head -n 1 || true)
            LOCAL_ANNOUNCE=$(ls -t ./podcasts/announce_*.wav 2>/dev/null \
                | grep -v '\.played' | head -n 1 || true)
            if [[ -n "$LOCAL_PODCAST" && -f "$LOCAL_PODCAST" ]]; then
                rm -f "$COVER_ART"; touch "$COVER_ART"
                [[ -n "$LOCAL_ANNOUNCE" && -f "$LOCAL_ANNOUNCE" ]] && \
                    { play_announce "$LOCAL_ANNOUNCE" || true; }
                play_podcast "$LOCAL_PODCAST" || true
                mark_podcast_played "$LOCAL_PODCAST"   # ← remplace les rm -f directs
                write_status "Musique" "" "" "" "" "0" ""
            else
                log "WARN : Aucun podcast .wav trouvé, run_podcast ignoré"
            fi
            ;;
        gen_news)
            write_last_event "$event_id"
            if [[ "$RADIO_ROLE" == "local" ]]; then
                generate_news &
                GEN_PID=$!
                wait_for_generation_with_music "gen_news"
            else
                log "⏭️  Génération news ignorée (rôle: $RADIO_ROLE)"
            fi
            ;;
        run_news)
            rm -f "$COVER_ART"; touch "$COVER_ART"
            if [[ -f "$NEWS_WAV" && -f "$WEATHER_WAV" ]]; then
                play_forecast
                play_news
                write_status "Musique" "" "" "" "" "0" ""
            else
                log "WARN : fichiers news manquants, diffusion ignorée"
            fi
            write_last_event "$event_id"
            ;;
        *)
            log "WARN : event_type inconnu : $event_type"
            write_last_event "$event_id"
            ;;
    esac
}

# =============================================================================
# STATUS
# =============================================================================

write_status() {
    local event="$1"
    local startedAt="$2"
    local title="${3:-}"
    local artist="${4:-}"
    local album="${5:-}"
    local duration="${6:-0}"
    local vtt_override="${7:-}"

    local now
    now=$(date +%s.%N 2>/dev/null || date +%s)

    local startedAtUnix currentTime endsAt
    if [[ -n "$startedAt" ]]; then
        startedAtUnix=$(date -d "$startedAt" +%s.%N 2>/dev/null || date -d "$startedAt" +%s)
        currentTime=$(python3 -c "print(max(0, min($duration, $now - $startedAtUnix)))" 2>/dev/null || echo 0)
        endsAt=$(python3 -c "print($startedAtUnix + $duration)" 2>/dev/null || echo 0)
    else
        startedAtUnix=0
        currentTime=0
        endsAt=0
    fi

    format_time() {
        local total_seconds=${1%.*}
        printf "%02d:%02d" "$(( total_seconds / 60 ))" "$(( total_seconds % 60 ))"
    }

    local time_readable duration_readable
    time_readable=$(format_time "$currentTime")
    duration_readable=$(format_time "$duration")

    local vttFile="$vtt_override"

    if [[ -z "$vttFile" ]]; then
        case $event in
            Annonce)  vttFile="/radio-gen/announce.vtt?t=$(date +%s)" ;;
            Podcast)  vttFile="/podcasts/podcast.vtt?t=$(date +%s)" ;;
            Météo)    vttFile="/radio-gen/weather.vtt?t=$(date +%s)" ;;
            News)     vttFile="/radio-gen/news.vtt?t=$(date +%s)" ;;
        esac
    fi

    local next_event_info next_time next_type next_field
    next_event_info=$(get_next_event_time)
    if [[ -n "$next_event_info" ]]; then
        next_time=$(echo "$next_event_info" | cut -d: -f2-3)
        next_type=$(echo "$next_event_info" | cut -d: -f4)
        next_field="\"nextEvent\": {\"time\": \"$next_time\", \"type\": \"$next_type\"}"
    else
        next_field="\"nextEvent\": null"
    fi

    title=$(echo "$title"   | sed 's/"/\\"/g')
    artist=$(echo "$artist" | sed 's/"/\\"/g')
    album=$(echo "$album"   | sed 's/"/\\"/g')

    cat > "$STATUS_JSON" <<EOF
{
  "event": "$event",
  "startedAt": "$startedAt",
  "endsAt": $endsAt,
  "serverNow": $now,
  "time": "$time_readable",
  "duration": "$duration_readable",
  "time_raw": $currentTime,
  "duration_raw": $duration,
  "vtt": "$vttFile",
  "title": "$title",
  "artist": "$artist",
  "album": "$album",
  $next_field
}
EOF
}

# =============================================================================
# LECTURE
# =============================================================================

mark_podcast_played() {
    local file="$1"
    touch "${file}.played-${RADIO_ROLE}"
    
    # Supprime si les 2 rôles ont joué
    if [[ -f "${file}.played-local" && -f "${file}.played-public" ]]; then
        local base="${file%.wav}"
        rm -f "$file" "${base}.txt" "${base}.vtt" \
              "${file}.played-local" "${file}.played-public"
        # Annonce associée (même timestamp)
        local ts=$(basename "$base" | sed 's/podcast_//')
        rm -f "./podcasts/announce_${ts}.wav"
        log "🗑️  Podcast ${ts} supprimé (joué par les 2 radios)"
    fi
}

play_file() {
    local file="$1"

    local duration title artist album
    local probe
    probe=$(ffprobe -v error -show_entries format=duration:format_tags=title,artist,album \
            -of default=noprint_wrappers=1 "$file" 2>/dev/null)

    duration=$(echo "$probe" | grep '^duration='   | cut -d= -f2  || true)
    title=$(echo    "$probe" | grep '^TAG:title='  | cut -d= -f2- || true)
    artist=$(echo   "$probe" | grep '^TAG:artist=' | cut -d= -f2- || true)
    album=$(echo    "$probe" | grep '^TAG:album='  | cut -d= -f2- || true)

    [[ -z "$duration" ]] && duration=0
    [[ -z "$title"    ]] && title=$(basename "$file")
    title=$(echo  "$title"  | sed 's/"/\\"/g')
    artist=$(echo "$artist" | sed 's/"/\\"/g')
    album=$(echo  "$album"  | sed 's/"/\\"/g')

    has_video=$(ffprobe -v quiet -select_streams v \
                -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | head -n 1)
    if [[ "$has_video" == "video" ]]; then
        ffmpeg -hide_banner -nostdin -i "$file" -map 0:v:0 -c:v copy \
               -f image2 "$COVER_ART" -y 2>/dev/null || true
    else
        rm -f "$COVER_ART"; touch "$COVER_ART"
    fi

    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    ( sleep 3 && update_icecast_metadata "$title" "$artist" "$album" ) &
    local META_PID=$!
    (while true; do
        write_status "Musique" "$now_iso" "$title" "$artist" "$album" "$duration" ""
        sleep 1
    done) &
    local UPDATE_PID=$!

    check_streamer
    stream_to_fifo "$file" || log "WARN : stream_to_fifo échoué pour $(basename "$file")"

    kill "$UPDATE_PID" 2>/dev/null || true
    kill "$META_PID"   2>/dev/null || true
}

play_next_track() {
    local playlist_dir
    playlist_dir="$(dirname "$(realpath "$PLAYLIST")")"

    local i=0
    while IFS= read -r line; do
        [[ "$line" =~ ^# || -z "$line" ]] && continue

        if [[ $i -eq $PLAYLIST_POS ]]; then
            local track="$line"
            [[ "$track" = /* ]] || track="$playlist_dir/$line"

            if [[ -f "$track" ]]; then
                log "♫  $(basename "$track")"
                play_file "$track"
            else
                log "WARN : introuvable : $track, ignoré"
            fi

            PLAYLIST_POS=$(( i + 1 ))
            return 0
        fi
        (( i++ )) || true
    done < "$PLAYLIST"

    log "🔀  Fin de playlist, nouveau shuffle..."
    shuf "$PLAYLIST" -o "$PLAYLIST"
    PLAYLIST_POS=0
    play_next_track
}
play_podcast() {
    local file_to_play="$1"
    local vtt_file="${file_to_play%.wav}.vtt"
    log "🎙️  Diffusion du podcast : $(basename "$file_to_play")"
    
    local duration start_iso STATUS_PID
    duration=$(ffprobe -v error -show_entries format=duration \
               -of default=noprint_wrappers=1:nokey=1 "$file_to_play")
    [[ -z "$duration" ]] && duration=0
    start_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    update_icecast_metadata "$(get_podcast)" "Chronique IA" ""

    (while true; do
        write_status "Podcast" "$start_iso" "$(get_podcast)" "Chronique IA" "" "$duration" "$vtt_file"
        sleep 1
    done) &
    STATUS_PID=$!

    stream_to_fifo "$file_to_play" "8dB" || log "WARN : stream podcast échoué"

    kill "$STATUS_PID" 2>/dev/null || true
    log "🎙️  Podcast terminé"
}

play_announce() {
    local file_to_play="$1"
    log "🎙️  Annonce du podcast: $(basename "$file_to_play")"
    local duration start_iso STATUS_PID
    duration=$(ffprobe -v error -show_entries format=duration \
               -of default=noprint_wrappers=1:nokey=1 "$file_to_play")
    [[ -z "$duration" ]] && duration=0
    start_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    update_icecast_metadata "Annonce" "Chronique IA" ""

    (while true; do
        write_status "Annonce" "$start_iso" "Annonce" "Chronique IA" "" "$duration" ""
        sleep 1
    done) &
    STATUS_PID=$!

    stream_to_fifo "$file_to_play" "8dB" || log "WARN : stream annonce échoué"

    kill "$STATUS_PID" 2>/dev/null || true
    log "🎙️  Annonce terminée"
}

play_news() {
    log "📰  Diffusion des news"
    local duration start_iso STATUS_PID
    duration=$(ffprobe -v error -show_entries format=duration \
               -of default=noprint_wrappers=1:nokey=1 "$NEWS_WAV")
    [[ -z "$duration" ]] && duration=0
    start_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    update_icecast_metadata "Flash Info" "News IA" ""

    (while true; do
        write_status "News" "$start_iso" "Flash info" "News IA" "" "$duration" ""
        sleep 1
    done) &
    STATUS_PID=$!

    stream_to_fifo "$NEWS_WAV" "8dB" || log "WARN : stream news échoué"

    kill "$STATUS_PID" 2>/dev/null || true
    log "📰  News terminées"
}

play_forecast() {
    log "☁️  Diffusion météo"
    local duration start_iso STATUS_PID
    duration=$(ffprobe -v error -show_entries format=duration \
               -of default=noprint_wrappers=1:nokey=1 "$WEATHER_WAV")
    [[ -z "$duration" ]] && duration=0
    start_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    update_icecast_metadata "Bulletin Météo" "News IA" ""

    (while true; do
        write_status "Météo" "$start_iso" "Bulletin Météo" "News IA" "" "$duration" ""
        sleep 1
    done) &
    STATUS_PID=$!

    stream_to_fifo "$WEATHER_WAV" "8dB" || log "WARN : stream météo échoué"

    kill "$STATUS_PID" 2>/dev/null || true
    log "☁️  Météo terminée"
}

# =============================================================================
# GÉNÉRATION
# =============================================================================

get_podcast() {
    local textfile=$(ls -t ./podcasts/podcast_*.txt 2>/dev/null | head -n 1)
    [[ -n "$textfile" && -f "$textfile" ]] || { echo "Podcast inconnu"; return; }
    sed -n '2p' "$textfile" | cut -c8-
}

generate_podcast() {
    log "⚙️  Génération du prochain podcast..."
    nice -n 19 bash "$PODCAST_GEN" --lang fr && \
        log "⚙️  Génération terminée" || \
        log "WARN : podcast run.sh erreur"
    local ts=$(date +%Y%m%d%H%M)
    mv ./podcast-generator/podcast.wav "./podcasts/podcast_${ts}.wav"
    mv ./podcast-generator/podcast_text.txt "./podcasts/podcast_${ts}.txt"
    mv ./podcast-generator/podcast.vtt "./podcasts/podcast_${ts}.vtt"
    find ./podcasts/ -name "podcast_*.wav" -mmin +$((24*60)) | while read -r f; do
        base="${f%.wav}"
        old_ts=$(basename "$base" | sed 's/podcast_//')
        rm -f "$f" "${base}.txt" "${base}.vtt" \
            "${f}.played-local" "${f}.played-public" \
            "./podcasts/announce_${old_ts}.wav"
    done
    local titre_actuel=$(sed -n '2p' "./podcasts/podcast_${ts}.txt" | cut -c8-)
    generate_announce "$titre_actuel" "$ts"
    
    log "✅  Prêt pour le prochain podcast"
}

generate_announce() {
    local topic="$1"
    local ts="$2"
    log "⚙️  Génération de l'annonce pour : $topic"
    
    bash "$RADIO_GEN" "podcast" "$topic" && \
        log "⚙️  Annonce générée" || \
        log "WARN : announce run.sh erreur"
        
    mv ./radio-generator/announce.wav "./podcasts/announce_${ts}.wav"
}

generate_forecast() {
    log "⚙️  Génération bulletin météo..."
    local hour=$(date +%H)
    local type="meteo"

    # Détermination du type de bulletin
    if (( 10#$hour >= 18 )); then
        type="meteo_demain"
    elif (( 10#$hour >= 10 )); then
        type="meteo_semaine"
    fi

    # Exécution unique
    if bash "$RADIO_GEN" "$type"; then
        log "⚙️  Météo générée ($type)"
    else
        log "WARN : erreur lors de l'exécution de $type"
        return 1
    fi
}

generate_news() {
    log "⚙️  Génération flash info..."
    nice -n 19 bash "$RADIO_GEN" "news" \
        "https://www.france24.com/fr/france/rss https://www.france24.com/fr/europe/rss https://www.france24.com/fr/rss https://www.bfmtv.com/rss/news-24-7/ https://www.franceinfo.fr/monde.rss https://www.franceinfo.fr/france.rss" 8 && \
        log "⚙️  Flash Info générée" || \
        log "WARN : news run.sh erreur"
    generate_forecast
    log "✅  Prêt pour le prochain flash info"
}

wait_for_generation_with_music() {
    local current_event="${1:-}"
    [[ -z "${GEN_PID:-}" ]] && return 0

    log "🎵  Musique pendant la génération..."

    local GEN_DONE_FLAG
    GEN_DONE_FLAG=$(mktemp /tmp/gen_done_XXXXXX)
    rm -f "$GEN_DONE_FLAG"

    ( wait "$GEN_PID" 2>/dev/null || true; touch "$GEN_DONE_FLAG" ) &
    local WATCHER_PID=$!

    while [[ ! -f "$GEN_DONE_FLAG" ]]; do
        local upcoming_raw upcoming_hhmm upcoming_type upcoming_id secs_left
        upcoming_raw=$(get_next_future_event 30)
        if [[ -n "$upcoming_raw" ]]; then
            upcoming_hhmm=$(echo "$upcoming_raw" | cut -d: -f1-2)
            upcoming_type=$(echo "$upcoming_raw" | cut -d: -f3)
            upcoming_id="${upcoming_hhmm}-${upcoming_type}"
            secs_left=$(seconds_until "$upcoming_hhmm")

            if [[ -n "$upcoming_type" \
               && "$upcoming_type" != "$current_event" \
               && "$secs_left" -le 30 ]]; then
                log "📅  Event imminent ($upcoming_type @ $upcoming_hhmm) — attente fin génération"
                wait "$WATCHER_PID" 2>/dev/null || true
                rm -f "$GEN_DONE_FLAG"
                GEN_PID=""
                dispatch_event "$upcoming_type" "$upcoming_id"
                return
            fi
        fi

        play_next_track
    done

    wait "$WATCHER_PID" 2>/dev/null || true
    rm -f "$GEN_DONE_FLAG"
    GEN_PID=""
}

# =============================================================================
# BOUCLE PRINCIPALE
# =============================================================================

EVENT_QUEUE=()

enqueue_event() {
    local event_id="$1"
    for item in "${EVENT_QUEUE[@]}"; do
        [[ "$item" == "$event_id" ]] && return 0
    done
    EVENT_QUEUE+=("$event_id")
    log "📥  Enfilé : $event_id (file: ${#EVENT_QUEUE[@]})"
}

flush_event_queue() {
    [[ ${#EVENT_QUEUE[@]} -eq 0 ]] && return 0
    local item hhmm type
    for item in "${EVENT_QUEUE[@]}"; do
        hhmm=$(echo "$item" | cut -d- -f1)
        type=$(echo "$item" | cut -d- -f2-)
        log "📤  Dépile et déclenche : $type @ $hhmm"
        dispatch_event "$type" "$item"
    done
    EVENT_QUEUE=()
}

seconds_since() {
    local hhmm="$1"
    python3 - <<EOF
from datetime import datetime
now = datetime.now()
h, m = map(int, "$hhmm".split(":"))
target = now.replace(hour=h, minute=m, second=0, microsecond=0)
diff = int((now - target).total_seconds())
print(diff if diff >= 0 else -1)
EOF
}

get_track_duration_at_pos() {
    local pos="$1"
    local playlist_dir="$(dirname "$(realpath "$PLAYLIST")")"
    local file=$(sed -n "$((pos + 1))p" "$PLAYLIST")
    
    if [[ -z "$file" || "$file" =~ ^# ]]; then
        echo 180 # Fallback 3 min
        return
    fi

    [[ "$file" = /* ]] || file="$playlist_dir/$file"
    
    local dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || echo 180)
    echo "${dur%.*}"
}

main_loop() {
    log "🗓️  Démarrage boucle principale"
    local last_dispatched_id=""

    while true; do
        flush_event_queue

        local upcoming_raw upcoming_hhmm upcoming_type upcoming_id secs_left track_duration

        upcoming_raw=$(get_next_future_event 0)

        # ── NOUVEAU : rattrapage via get_pending_event si get_next_future_event est vide ──
        if [[ -z "$upcoming_raw" ]]; then
            local pending_raw
            pending_raw=$(get_pending_event)
            if [[ -n "$pending_raw" ]]; then
                local pending_hhmm pending_type pending_id pending_late
                pending_hhmm=$(echo "$pending_raw" | cut -d: -f1-2)
                pending_type=$(echo "$pending_raw"  | cut -d: -f3)
                pending_id="${pending_hhmm}-${pending_type}"
                pending_late=$(seconds_since "$pending_hhmm")
                if [[ "$pending_late" -ge 0 && "$pending_late" -lt 1800 \
                   && "$pending_id" != "$last_dispatched_id" ]]; then
                    log "⚠️ Rattrapage (pending) : $pending_type (${pending_late}s de retard)"
                    last_dispatched_id="$pending_id"
                    enqueue_event "$pending_id"
                    flush_event_queue
                    continue
                fi
            fi
        fi
        # ── FIN NOUVEAU ──

        if [[ -n "$upcoming_raw" ]]; then
            upcoming_hhmm=$(echo "$upcoming_raw" | cut -d: -f1-2)
            upcoming_type=$(echo "$upcoming_raw"  | cut -d: -f3)
            upcoming_id="${upcoming_hhmm}-${upcoming_type}"
            secs_left=$(seconds_until "$upcoming_hhmm")

            track_duration=$(get_track_duration_at_pos $PLAYLIST_POS)

            if [[ "$secs_left" -gt 0 && "$secs_left" -le 300 ]]; then
                if [[ "$secs_left" -le "$track_duration" || "$secs_left" -le 30 ]]; then
                    if [[ "$upcoming_id" != "$last_dispatched_id" ]]; then
                        log "📅 Événement $upcoming_type imminent (${secs_left}s)..."
                        last_dispatched_id="$upcoming_id"
                        enqueue_event "$upcoming_id"
                        flush_event_queue
                    fi
                fi
            fi
            
            late=$(seconds_since "$upcoming_hhmm")
            if [[ "$secs_left" -le 0 && "$late" -ge 30 && "$late" -lt 1800 \
               && "$upcoming_id" != "$last_dispatched_id" ]]; then
                log "⚠️ Retard détecté pour $upcoming_type (${late}s) → rattrapage immédiat."
                last_dispatched_id="$upcoming_id"
                enqueue_event "$upcoming_id"
                flush_event_queue
                continue
            fi
        fi

        play_next_track
        if [[ -n "$last_dispatched_id" ]]; then
            local last_hhmm
            last_hhmm=$(echo "$last_dispatched_id" | cut -d- -f1)
            [[ "$(seconds_until "$last_hhmm")" -lt 0 ]] && last_dispatched_id=""
        fi
    done
}

# =============================================================================
# DÉMARRAGE
# =============================================================================

handle_startup_events() {
    log "🔍  Vérification des events manqués au démarrage..."

    local next_raw next_hhmm secs_to_next
    next_raw=$(get_next_future_event 0)
    if [[ -n "$next_raw" ]]; then
        next_hhmm=$(echo "$next_raw" | cut -d: -f1-2)
        secs_to_next=$(seconds_until "$next_hhmm")
        if [[ "$secs_to_next" -le 600 ]]; then
            log "⏭️  Rattrapage ignoré : prochain event dans ${secs_to_next}s (< 10 min)"
            return
        fi
    fi

    local missed
    missed=$(get_missed_events)

    if [[ -z "$missed" ]]; then
        log "✅  Aucun event manqué."
        return
    fi

    local last_line last_missed_hhmm last_missed_type last_missed_id
    last_line=$(echo "$missed" | tail -n1)
    last_missed_hhmm=$(echo "$last_line" | cut -d: -f1-2)
    last_missed_type=$(echo "$last_line" | cut -d: -f3)
    last_missed_id="${last_missed_hhmm}-${last_missed_type}"

    case "$last_missed_type" in
        gen_*)
            log "⚙️  Rattrapage : relance de $last_missed_type (manqué à $last_missed_hhmm)"
            dispatch_event "$last_missed_type" "$last_missed_id"
            ;;
        *)
            log "⏭️  Rattrapage ignoré : ($last_missed_type)"
            write_last_event "$last_missed_id"
            ;;
    esac
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log "📻  Démarrage de la radio"
    write_status "Musique" "" "" "" "" "0" ""

    if [[ -d "radio-generator/.git" ]]; then
        (cd radio-generator && git pull)
    else
        git clone https://github.com/AdrienPiechocki/radio-generator.git
    fi

    if [[ -d "podcast-generator/.git" ]]; then
        (cd podcast-generator && git pull)
    else
        git clone https://github.com/AdrienPiechocki/podcast-generator.git
    fi

    cd "$SCRIPT_DIR"

    if [[ "$RADIO_ROLE" == "local" ]]; then
        [[ -f "$NEWS_WAV"    ]] && rm -f "$NEWS_WAV"
        [[ -f "$WEATHER_WAV" ]] && rm -f "$WEATHER_WAV"
    fi

    mkdir -p ./podcasts
    
    MUSIC_DIR="${MUSIC_DIR:-./music}"
    mkdir -p "$MUSIC_DIR"
    [[ -z "$(ls -A "$MUSIC_DIR")" ]] && { log "ERREUR: ajoutez de la musique dans $MUSIC_DIR"; exit 1; }

    echo "#EXTM3U" > "$PLAYLIST"
    find "$MUSIC_DIR" -type f -name "*.mp3" -print0 \
    | shuf -z \
    | while IFS= read -r -d '' file; do echo "$file" >> "$PLAYLIST"; done

    [[ -f "$PLAYLIST"    ]] || { log "ERREUR : $PLAYLIST introuvable";    exit 1; }
    [[ -f "$PODCAST_GEN" ]] || { log "ERREUR : $PODCAST_GEN introuvable"; exit 1; }
    [[ -f "$RADIO_GEN"   ]] || { log "ERREUR : $RADIO_GEN introuvable";   exit 1; }

    log "⏳  Attente d'Icecast sur ${ICECAST_HOST}:${ICECAST_PORT}..."
    for i in $(seq 1 30); do
        if (command -v curl >/dev/null && \
            curl -sf "http://${ICECAST_HOST}:${ICECAST_PORT}/" -o /dev/null 2>/dev/null) || \
           (exec 9<>/dev/tcp/${ICECAST_HOST}/${ICECAST_PORT} 2>/dev/null && exec 9>&-); then
            log "✅  Icecast prêt"
            break
        fi
        sleep 1
    done

    if ! start_streamer; then
        log "❌  Impossible de démarrer le streamer, attente 10s avant retry..."
        sleep 10
        exit 1
    fi

    handle_startup_events

    main_loop
}

cleanup() {
    log "🛑  Arrêt du service radio"
    exec 3>&- 2>/dev/null || true
    [[ -n "${FFMPEG_PID:-}" ]] && kill "$FFMPEG_PID" 2>/dev/null || true
    [[ -n "${GEN_PID:-}"    ]] && kill "$GEN_PID"    2>/dev/null || true
    write_status "Musique" "" "" "" "" "0" ""
    rm -f "$FIFO"
    exit 0
}
trap cleanup SIGTERM SIGINT

main