#!/usr/bin/env bash
# =============================================================================
# radio.sh — avec scheduling depuis schedule.json
# =============================================================================

set -euo pipefail
export TZ="Europe/Paris"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PLAYLIST_POS=0

STATUS_JSON="./status.json"
SCHEDULE_JSON="./schedule.json"

PODCAST_WAV="./podcast-generator/podcast.wav"
PODCAST_GEN="./podcast-generator/run.sh"
PODCAST_TEXT="./podcast-generator/podcast_text.txt"
PLAYLIST="./playlist.m3u"
ANNOUNCE_WAV="./radio-generator/announce.wav"
NEWS_WAV="./radio-generator/news.wav"
WEATHER_WAV="./radio-generator/weather.wav"
RADIO_GEN="./radio-generator/run.sh"

ICECAST_HOST="${ICECAST_HOST:-icecast}"
ICECAST_PORT="${ICECAST_PORT:-8000}"
ICECAST_SOURCE_PASSWORD="${ICECAST_SOURCE_PASSWORD:-hackme}"
ICECAST_MOUNT="${ICECAST_MOUNT:-/radio}"

GEN_PID=""
MUSIC_PID=""
TIMER_PID=""
FFMPEG_PID=""
FIFO="/tmp/radio_pipe"

log() { echo "[$(date '+%H:%M:%S %Z')] $*"; }

# =============================================================================
# SCHEDULING
# =============================================================================

# Retourne l'event_type si un event est schedulé dans les N prochaines secondes
# Usage: get_upcoming_event [lookahead_seconds=120]
get_upcoming_event() {
    local lookahead="${1:-120}"
    [[ -f "$SCHEDULE_JSON" ]] || return 0

    local now_min now_hour now_total_min
    now_hour=$(date +%-H)
    now_min=$(date +%-M)
    now_total_min=$(( now_hour * 60 + now_min ))

    python3 - <<EOF
import json, sys

with open("$SCHEDULE_JSON") as f:
    schedule = json.load(f)

now_total = $now_total_min
lookahead_min = $lookahead / 60.0

for time_str, event_type in schedule.items():
    parts = time_str.strip().split(":")
    if len(parts) != 2:
        continue
    h, m = int(parts[0]), int(parts[1])
    event_total = h * 60 + m

    # Gestion minuit (ex: event à 00:30 depuis 23:50)
    diff = event_total - now_total
    if diff < -720:   # plus de 12h dans le passé → probablement demain
        diff += 1440
    elif diff > 720:  # plus de 12h dans le futur → probablement hier
        diff -= 1440

    if 0 <= diff <= lookahead_min:
        print(event_type)
        sys.exit(0)

sys.exit(0)
EOF
}

# Retourne l'horaire exact (HH:MM) du prochain event à venir
get_next_event_time() {
    [[ -f "$SCHEDULE_JSON" ]] || return 0

    python3 - <<EOF
# À remplacer dans votre fonction get_next_event_time
import json, sys, datetime

with open("$SCHEDULE_JSON") as f:
    schedule = json.load(f)

now = datetime.datetime.now()
now_total = now.hour * 60 + now.minute

# On trie les événements par heure
sorted_events = sorted(schedule.items(), key=lambda x: int(x[0].split(':')[0])*60 + int(x[0].split(':')[1]))

# On cherche le dernier événement dont l'heure est passée
last_due_event = None
for time_str, event_type in sorted_events:
    h, m = map(int, time_str.split(":"))
    event_total = h * 60 + m
    
    if now_total >= event_total:
        last_due_event = (time_str, event_type)
    else:
        # Dès qu'on trouve un event dans le futur, on s'arrête
        break

if last_due_event:
    # On renvoie l'event le plus récent qui est "dû"
    print(f"TRIGGER:{last_due_event[0]}:{last_due_event[1]}")
else:
    # Sinon on affiche juste le prochain pour le statut
    next_event = sorted_events[0] # Simplification : premier de la liste
    print(f"WAIT:{next_event[0]}:{next_event[1]}")
EOF
}

# Secondes restantes avant HH:MM
seconds_until() {
    local hhmm="$1"
    local target_h target_m
    target_h=$(echo "$hhmm" | cut -d: -f1)
    target_m=$(echo "$hhmm" | cut -d: -f2)

    python3 - <<EOF
import time
from datetime import datetime, timedelta

now = datetime.now()
target = now.replace(hour=int("$target_h"), minute=int("$target_m"), second=0, microsecond=0)
if target <= now:
    target += timedelta(days=1)
print(int((target - now).total_seconds()))
EOF
}

# Dispatch d'un event schedulé
dispatch_event() {
    local event_type="$1"
    log "📅  Event schedulé : $event_type"

    case "$event_type" in
        gen_podcast)
            generate_podcast &
            GEN_PID=$!
            wait_for_generation_with_music "gen_podcast"
            log "✅  Prêt pour le prochain podcast"
            ;;
        run_podcast)
            if [[ -f "$PODCAST_WAV" && -f "$ANNOUNCE_WAV" ]]; then
                play_announce
                play_podcast
                write_status "Musique" "" "" "" "0"
            else
                log "WARN : fichiers manquants, diffusion ignorée"
            fi
            ;;
        gen_news)
            generate_news &
            GEN_PID=$!
            wait_for_generation_with_music "gen_news"
            log "✅  Prêt pour le prochain flash info"
            ;;
        run_news)
            if [[ -f "$NEWS_WAV" && -f "$WEATHER_WAV" ]]; then
                play_forecast
                play_news
                write_status "Musique" "" "" "" "0"
            else
                log "WARN : fichiers manquants, diffusion ignorée"
            fi
            ;;
        *)
            log "WARN : event_type inconnu : $event_type"
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
    local duration="${5:-0}"

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

    local vttFile=""
    case $event in
        Annonce)  vttFile="/radio-gen/announce.vtt?t=$(date +%s)" ;;
        Podcast)  vttFile="/podcasts/podcast.vtt?t=$(date +%s)" ;;
        Météo)    vttFile="/radio-gen/weather.vtt?t=$(date +%s)" ;;
        News)    vttFile="/radio-gen/news.vtt?t=$(date +%s)" ;;
    esac

    # Prochain event schedulé
    local next_event_info next_time next_type next_field
    next_event_info=$(get_next_event_time)
    if [[ -n "$next_event_info" ]]; then
        next_time=$(echo "$next_event_info" | cut -d: -f2-3)
        next_type=$(echo "$next_event_info" | cut -d: -f4)
        next_field="\"nextEvent\": {\"time\": \"$next_time\", \"type\": \"$next_type\"}"
    else
        next_field="\"nextEvent\": null"
    fi

    title=$(echo "$title"  | sed 's/"/\\"/g')
    artist=$(echo "$artist" | sed 's/"/\\"/g')

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
  $next_field
}
EOF
}

# =============================================================================
# FFMPEG / FIFO
# =============================================================================

start_ffmpeg_streamer() {
    rm -f "$FIFO"
    mkfifo "$FIFO"
    log "🔌  Connexion à Icecast ${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT}"

    ffmpeg \
        -hide_banner -nostdin \
        -re \
        -f s16le -ar 44100 -ac 2 \
        -i "$FIFO" \
        -codec:a libmp3lame -b:a 128k -ar 44100 \
        -ice_name "Radio Locale" \
        -ice_description "Ma radio IA" \
        -content_type audio/mpeg \
        -f mp3 \
        "icecast://source:${ICECAST_SOURCE_PASSWORD}@${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT}" \
        -loglevel warning &
    FFMPEG_PID=$!
    log "🎚️  ffmpeg streamer démarré (PID $FFMPEG_PID)"
}

play_file() {
    local file="$1"

    local info duration title artist
    info=$(ffprobe -v error -show_entries format=duration:format_tags=title,artist \
           -of default=noprint_wrappers=1:nokey=1 "$file")
    duration=$(echo "$info" | sed -n '1p')
    title=$(echo "$info"    | sed -n '2p')
    artist=$(echo "$info"   | sed -n '3p')

    [[ -z "$duration" ]] && duration=0
    [[ -z "$title"    ]] && title=$(basename "$file")
    title=$(echo "$title"   | sed 's/"/\\"/g')
    artist=$(echo "$artist" | sed 's/"/\\"/g')

    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    (
        while kill -0 $BASHPID 2>/dev/null; do
            write_status "Musique" "$now_iso" "$title" "$artist" "$duration"
            sleep 1
        done
    ) &
    local UPDATE_PID=$!

    ffmpeg -hide_banner -nostdin -i "$file" \
           -f s16le -ar 44100 -ac 2 -loglevel quiet - >> "$FIFO"

    kill "$UPDATE_PID" 2>/dev/null || true
}

# =============================================================================
# LECTURE
# =============================================================================

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
                play_file "$track" &
                MUSIC_PID=$!
                wait "$MUSIC_PID" || true
                MUSIC_PID=""
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
    log "🎙️  Diffusion du podcast"
    local duration start_iso STATUS_PID
    duration=$(ffprobe -v error -show_entries format=duration \
               -of default=noprint_wrappers=1:nokey=1 "$PODCAST_WAV")
    [[ -z "$duration" ]] && duration=0
    start_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    (while true; do
        write_status "Podcast" "$start_iso" "$(get_podcast)" "Radio DEV" "$duration"
        sleep 1
    done) &
    STATUS_PID=$!

    ffmpeg -hide_banner -nostdin -i "$PODCAST_WAV" \
           -f s16le -ar 44100 -ac 2 -loglevel quiet - >> "$FIFO"

    log "🎙️  Podcast terminé"
    kill "$STATUS_PID" 2>/dev/null || true
}

play_announce() {
    log "🎙️  Annonce"
    local duration start_iso STATUS_PID
    duration=$(ffprobe -v error -show_entries format=duration \
               -of default=noprint_wrappers=1:nokey=1 "$ANNOUNCE_WAV")
    [[ -z "$duration" ]] && duration=0
    start_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    (while true; do
        write_status "Annonce" "$start_iso" "Chronique IA" "Radio DEV" "$duration"
        sleep 1
    done) &
    STATUS_PID=$!

    ffmpeg -hide_banner -nostdin -i "$ANNOUNCE_WAV" \
           -f s16le -ar 44100 -ac 2 -loglevel quiet - >> "$FIFO"

    log "🎙️  Annonce terminée"
    kill "$STATUS_PID" 2>/dev/null || true
}

play_news() {
    log "📰  Diffusion des news"
    local duration start_iso STATUS_PID
    duration=$(ffprobe -v error -show_entries format=duration \
               -of default=noprint_wrappers=1:nokey=1 "$NEWS_WAV")
    [[ -z "$duration" ]] && duration=0
    start_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    (while true; do
        write_status "News" "$start_iso" "Flash info" "Radio DEV" "$duration"
        sleep 1
    done) &
    STATUS_PID=$!

    ffmpeg -hide_banner -nostdin -i "$NEWS_WAV" \
           -f s16le -ar 44100 -ac 2 -loglevel quiet - >> "$FIFO"

    log "📰  News terminées"
    kill "$STATUS_PID" 2>/dev/null || true
}

play_forecast() {
    log "Diffusion météo"
    local duration start_iso STATUS_PID
    duration=$(ffprobe -v error -show_entries format=duration \
               -of default=noprint_wrappers=1:nokey=1 "$WEATHER_WAV")
    [[ -z "$duration" ]] && duration=0
    start_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    (while true; do
        write_status "Météo" "$start_iso" "Buletin Météo" "Radio DEV" "$duration"
        sleep 1
    done) &
    STATUS_PID=$!

    ffmpeg -hide_banner -nostdin -i "$WEATHER_WAV" \
           -f s16le -ar 44100 -ac 2 -loglevel quiet - >> "$FIFO"

    log "Fin de la météo"
    kill "$STATUS_PID" 2>/dev/null || true
}

# =============================================================================
# GÉNÉRATION
# =============================================================================

get_podcast() {
    [[ -f "$PODCAST_TEXT" ]] || { echo "Podcast inconnu"; return; }
    sed -n '2p' "$PODCAST_TEXT" | cut -c8-
}

generate_podcast() {
    log "⚙️  Génération du prochain podcast..."
    bash "$PODCAST_GEN" --lang fr && \
        log "⚙️  Génération terminée" || \
        log "WARN : podcast run.sh erreur"
    generate_announce "$(get_podcast)"
}

generate_announce() {
    local topic="$1"
    log "⚙️  Génération de l'annonce..."
    bash "$RADIO_GEN" "podcast" "$topic" && \
        log "⚙️  Annonce générée" || \
        log "WARN : announce run.sh erreur"
}

generate_forecast() {
    log "⚙️  Génération bultin météo..."
    local hour
    hour=$(date +%H)
    if (( 10#$hour >= 18 )); then
        bash "$RADIO_GEN" "meteo_demain" "" && \
            log "⚙️  Météo générée (soir)" || \
            log "WARN : meteo run.sh erreur"
    else
        bash "$RADIO_GEN" "meteo" "" && \
            log "⚙️  Météo générée" || \
            log "WARN : meteo run.sh erreur"
    fi
}

generate_news() {
    log "⚙️  Génération flash info..."
    bash "$RADIO_GEN" "news" "https://www.france24.com/fr/rss" && \
        log "⚙️  Flash Info générée" || \
        log "WARN : news run.sh erreur"
    generate_forecast
}

wait_for_generation_with_music() {
    local current_event="${1:-}"
    [[ -z "${GEN_PID:-}" ]] && return 0

    log "🎵  Musique pendant la génération..."
    while kill -0 "$GEN_PID" 2>/dev/null; do
        # Vérifie si un NOUVEL event est imminent (lookahead 30s)
        local upcoming
        upcoming=$(get_upcoming_event 30)
        
        # Si un event arrive ET que ce n'est pas celui qu'on traite déjà
        if [[ -n "$upcoming" && "$upcoming" != "$current_event" ]]; then
            log "📅  NOUVEL event imminent ($upcoming) — on termine la génération actuelle"
            wait "$GEN_PID" || true
            GEN_PID=""
            dispatch_event "$upcoming"
            return
        fi
        
        # Joue une piste. Si la piste finit, la boucle while check à nouveau GEN_PID
        play_next_track
    done

    wait "$GEN_PID" || true
    GEN_PID=""
}

# =============================================================================
# BOUCLE PRINCIPALE AVEC SCHEDULE
# =============================================================================

LAST_EVENT_ID=""

main_loop() {
    log "🗓️  Démarrage boucle principale"

    while true; do
        # 1. Jouer la musique (attend la fin du morceau)
        play_next_track

        # 2. Vérifier le planning
        local schedule_info
        schedule_info=$(get_next_event_time)
        
        local mode=$(echo "$schedule_info" | cut -d: -f1)
        local event_time=$(echo "$schedule_info" | cut -d: -f2-3)
        local event_type=$(echo "$schedule_info" | cut -d: -f4)

        if [[ "$mode" == "TRIGGER" ]]; then
            # On vérifie si cet événement précis (heure+type) a déjà été fait
            if [[ "$LAST_EVENT_ID" != "$event_time-$event_type" ]]; then
                log "⏰ HEURE DÉPASSÉE ($event_time) : Lancement de $event_type"
                dispatch_event "$event_type"
                LAST_EVENT_ID="$event_time-$event_type"
            fi
        fi

        # 3. Nettoyage rapide des processus de génération en arrière-plan
        if [[ -n "${GEN_PID:-}" ]] && ! kill -0 "$GEN_PID" 2>/dev/null; then
            wait "$GEN_PID" || true
            GEN_PID=""
        fi
    done
}

# Retourne la durée de la prochaine track sans la jouer
get_next_track_duration() {
    local playlist_dir
    playlist_dir="$(dirname "$(realpath "$PLAYLIST")")"
    local i=0
    while IFS= read -r line; do
        [[ "$line" =~ ^# || -z "$line" ]] && continue
        if [[ $i -eq $PLAYLIST_POS ]]; then
            local track="$line"
            [[ "$track" = /* ]] || track="$playlist_dir/$line"
            if [[ -f "$track" ]]; then
                ffprobe -v error -show_entries format=duration \
                        -of default=noprint_wrappers=1:nokey=1 "$track" 2>/dev/null || echo ""
            fi
            return
        fi
        (( i++ )) || true
    done < "$PLAYLIST"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log "📻  Démarrage de la radio"
    write_status "Musique" "" "" "" "0"

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

    [[ -f $PODCAST_WAV ]] && { rm -f $PODCAST_WAV; }
    [[ -f $ANNOUNCE_WAV ]] && { rm -f $ANNOUNCE_WAV; }
    [[ -f $NEWS_WAV ]] && { rm -f $NEWS_WAV; }
    [[ -f $WEATHER_WAV ]] && { rm -f $WEATHER_WAV; }

    echo "#EXTM3U" > "playlist.m3u"
    find "./music" -type f -name "*.mp3" -print0 \
      | shuf -z \
      | while IFS= read -r -d '' file; do echo "$file" >> "playlist.m3u"; done

    [[ -f "$PLAYLIST"    ]] || { log "ERREUR : $PLAYLIST introuvable";   exit 1; }
    [[ -f "$PODCAST_GEN" ]] || { log "ERREUR : $PODCAST_GEN introuvable"; exit 1; }

    log "⏳  Attente d'Icecast sur ${ICECAST_HOST}:${ICECAST_PORT}..."
    for i in $(seq 1 30); do
        if (command -v curl >/dev/null && \
            curl -sf "http://${ICECAST_HOST}:${ICECAST_PORT}/" -o /dev/null 2>/dev/null) || \
           (exec 3<>/dev/tcp/${ICECAST_HOST}/${ICECAST_PORT} 2>/dev/null); then
            log "✅  Icecast prêt"
            [[ -n "${AS_FD:-}" ]] && exec 3>&-
            break
        fi
        sleep 1
    done

    start_ffmpeg_streamer
    sleep 4

    main_loop
}

cleanup() {
    log "🛑  Arrêt du service radio"
    [[ -n "${MUSIC_PID:-}"  ]] && kill "$MUSIC_PID"  2>/dev/null || true
    [[ -n "${TIMER_PID:-}"  ]] && kill "$TIMER_PID"  2>/dev/null || true
    [[ -n "${FFMPEG_PID:-}" ]] && kill "$FFMPEG_PID" 2>/dev/null || true
    [[ -n "${GEN_PID:-}"    ]] && kill "$GEN_PID"    2>/dev/null || true
    write_status "Musique" "" "" "" "0"
    rm -f "$FIFO"
    exit 0
}
trap cleanup SIGTERM SIGINT

main