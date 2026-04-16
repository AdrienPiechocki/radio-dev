#!/usr/bin/env bash
# =============================================================================
# radio.sh — Fixed Version
# =============================================================================

set -euo pipefail

PLAYLIST_POS=0

STATUS_JSON="./podcast-generator/podcast-status.json"

PODCAST_WAV="./podcast-generator/podcast.wav"
PODCAST_GEN="./podcast-generator/run.sh"
PODCAST_VTT="./podcast-generator/podcast.vtt"
PLAYLIST="./playlist.m3u"

ICECAST_HOST="${ICECAST_HOST:-icecast}"
ICECAST_PORT="${ICECAST_PORT:-8000}"
ICECAST_SOURCE_PASSWORD="${ICECAST_SOURCE_PASSWORD:-hackme}"
ICECAST_MOUNT="${ICECAST_MOUNT:-/radio}"

GEN_PID=""
MUSIC_PID=""
TIMER_PID=""
FFMPEG_PID=""
FIFO="/tmp/radio_pipe"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

write_status() {
    local isPodcast="$1"
    local startedAt="$2"
    local title="${3:-}"
    local artist="${4:-}"
    local album="${5:-}"
    local duration="${6:-0}"

    mkdir -p "$(dirname "$STATUS_JSON")"

    local now
    now=$(date +%s.%N 2>/dev/null || date +%s)

    local startedAtUnix
    startedAtUnix=$(date -d "$startedAt" +%s.%N 2>/dev/null || date -d "$startedAt" +%s)
    
    # Calcul des secondes brutes (float)
    local currentTime
    currentTime=$(python3 -c "print(max(0, min($duration, $now - $startedAtUnix)))" 2>/dev/null || echo 0)
    
    local endsAt
    endsAt=$(python3 -c "print($startedAtUnix + $duration)" 2>/dev/null || echo 0)

    # --- FORMATION MM:SS ---
    # Fonction interne pour convertir secondes -> MM:SS
    format_time() {
        local total_seconds=${1%.*} # On retire les décimales pour le formatage
        local mins=$(( total_seconds / 60 ))
        local secs=$(( total_seconds % 60 ))
        printf "%02d:%02d" "$mins" "$secs"
    }

    local time_readable
    time_readable=$(format_time "$currentTime")
    
    local duration_readable
    duration_readable=$(format_time "$duration")

    local isPodcastJson="false"
    [[ "$isPodcast" == "true" || "$isPodcast" == "1" ]] && isPodcastJson="true"

    cat > "$STATUS_JSON" <<EOF
{
  "isPodcast": $isPodcastJson,
  "startedAt": "$startedAt",
  "endsAt": $endsAt,
  "serverNow": $now,
  "time": "$time_readable",
  "duration": "$duration_readable",
  "time_raw": $currentTime,
  "duration_raw": $duration,
  "vtt": "/podcasts/podcast.vtt?t=$(date +%s)",
  "title": "$title",
  "artist": "$artist",
  "album": "$album"
}
EOF
}

measure_latency_loop() {
    log "📡 Démarrage mesure latence Icecast"

    while true; do
        # estimation basée sur buffer mp3 (128kbps ≈ ~1s / 16KB)
        # FIFO + ffmpeg + réseau → approx

        # méthode simple mais stable :
        local queue_size
        queue_size=$(stat -c%s "$FIFO" 2>/dev/null || echo 0)

        # estimation
        local estimated
        estimated=$(python3 - <<EOF
q=$queue_size
# approx bytes → secondes (128kbps)
print(max(2.5, min(8.0, q / 16000)))
EOF
)

        STREAM_OFFSET="$estimated"

        log "📏 Latence estimée: ${STREAM_OFFSET}s"

        sleep 5
    done
}

play_next_track() {
    if [[ -f "/tmp/skip_track" ]]; then
        rm -f "/tmp/skip_track"
        log "⏭️ Skip détecté avant le début de la piste"
    fi
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
    
    # Fin de playlist → on repart au début avec un nouveau shuffle
    log "🔀  Fin de playlist, nouveau shuffle..."
    shuf "$PLAYLIST" -o "$PLAYLIST"
    PLAYLIST_POS=0
    play_next_track
}

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
        -loglevel warning \
        &
    FFMPEG_PID=$!
    log "🎚️  ffmpeg streamer démarré (PID $FFMPEG_PID)"
}

play_file() {
    local file="$1"
    
    # Extraction métadonnées (votre code actuel)
    local info
    info=$(ffprobe -v error -show_entries format=duration:format_tags=title,artist,album -of default=noprint_wrappers=1:nokey=1 "$file")
    local duration=$(echo "$info" | sed -n '1p')
    local title=$(echo "$info" | sed -n '2p')
    local artist=$(echo "$info" | sed -n '3p')
    local album=$(echo "$info" | sed -n '4p')

    [[ -z "$duration" ]] && duration=0
    [[ -z "$title" ]] && title=$(basename "$file")
    
    local now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # --- MONITEUR DE SKIP ---
    # On lance ffmpeg en arrière-plan pour pouvoir le contrôler
    ffmpeg -hide_banner -nostdin -i "$file" -f s16le -ar 44100 -ac 2 -loglevel quiet - >> "$FIFO" &
    local FFMPEG_PLAY_PID=$!

    # On lance un moniteur qui attend soit la fin du morceau, soit le fichier de skip
    (
        while kill -0 $FFMPEG_PLAY_PID 2>/dev/null; do
            if [[ -f "/tmp/skip_track" ]]; then
                log "⏭️ Skip reçu ! Arrêt de la piste en cours."
                rm -f "/tmp/skip_track"
                kill $FFMPEG_PLAY_PID 2>/dev/null || true
                break
            fi
            # Mise à jour du JSON de statut (optionnel, réutilise votre logique)
            write_status false "$now_iso" "$title" "$artist" "$album" "$duration"
            sleep 1
        done
    ) &
    local MONITOR_PID=$!

    # On attend que ffmpeg finisse (naturellement ou tué par le moniteur)
    wait $FFMPEG_PLAY_PID 2>/dev/null || true
    kill $MONITOR_PID 2>/dev/null || true
}

skip_track() {
    if [[ -n "${MUSIC_PID:-}" ]]; then
        log "⏭️  Skip demandé (Signal SIGTERM envoyé à $MUSIC_PID)"
        kill "$MUSIC_PID" 2>/dev/null || true
    else
        log "⚠️  Aucune piste en cours de lecture à sauter."
    fi
}

seconds_to_next_half_hour() {
    local now_min now_sec
    now_min=$(date +%-M)
    now_sec=$(date +%-S)
    
    if [ "$now_min" -lt 30 ]; then
        echo $(( (30 - now_min) * 60 - now_sec ))
    else
        echo $(( (60 - now_min) * 60 - now_sec ))
    fi
}

run_podcast() {
    if [[ -f "$PODCAST_WAV" ]]; then
        log "🎙️  Diffusion du podcast"
        
        # 1. Extraction de la durée du podcast
        local duration
        duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$PODCAST_WAV")
        [[ -z "$duration" ]] && duration=0

        local start_iso
        start_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # 2. Lancement du rafraîchissement du statut en arrière-plan
        # On passe "true" pour isPodcast, puis les métadonnées spécifiques
        (
            while true; do
                write_status true "$start_iso" "Chronique IA" "Radio DEV" "" "$duration"
                sleep 1
            done
        ) &
        STATUS_PID=$!

        # 3. Lecture effective
        ffmpeg -hide_banner -nostdin -i "$PODCAST_WAV" -f s16le -ar 44100 -ac 2 -loglevel quiet - >> "$FIFO"

        log "🎙️  Podcast terminé"
        kill "$STATUS_PID" 2>/dev/null || true

        # Reset du statut vers le mode musique
        write_status false "" "" "" "" "0"
    else
        log "WARN : $PODCAST_WAV introuvable, diffusion ignorée"
    fi

    # --- Suite du script (Génération du prochain podcast) ---
    start_podcast_generation
    wait_for_generation_with_music
    log "✅  Prêt pour le prochain podcast"
}

should_generate_podcast() {
    local wait_sec
    wait_sec=$(seconds_to_next_half_hour)

    if (( wait_sec > 600 )); then
        return 0
    else
        return 1
    fi
}

generate_podcast() {
    log "⚙️  Génération du prochain podcast en arrière-plan..."

    bash "$PODCAST_GEN" --lang fr && \
        log "⚙️  Génération terminée" \
        || log "WARN : run.sh a retourné une erreur"
}

start_podcast_generation() {
    if should_generate_podcast; then
        log "🧠 Génération autorisée (créneau OK)"
        generate_podcast &
        GEN_PID=$!
    else
        log "⏱️ Trop proche du créneau → génération skip"
        GEN_PID=""
    fi
}

wait_for_generation_with_music() {
    if [[ -z "${GEN_PID:-}" ]]; then
        return 0
    fi

    log "🎵  Musique pendant la génération..."
    while kill -0 "$GEN_PID" 2>/dev/null; do
        play_next_track
    done

    wait "$GEN_PID" || true
    GEN_PID=""
}

main() {
    log "📻  Démarrage de la radio"
    
    rm -f "/tmp/skip_track"
    mkdir -p "$(dirname "$STATUS_JSON")"

    write_status false ""

    echo "#EXTM3U" > "playlist.m3u"

    find "./music" -type f -name "*.mp3" -print0 \
      | shuf -z \
      | while IFS= read -r -d '' file; do
          echo "$file" >> "playlist.m3u"
        done

    [[ -f "$PLAYLIST" ]]    || { log "ERREUR : $PLAYLIST introuvable"; exit 1; }
    [[ -f "$PODCAST_GEN" ]] || { log "ERREUR : $PODCAST_GEN introuvable"; exit 1; }

    log "⏳  Attente d'Icecast sur ${ICECAST_HOST}:${ICECAST_PORT}..."
    
    # Check if curl exists; if not, use the shell /dev/tcp trick we discussed
    for i in $(seq 1 30); do
        if (command -v curl >/dev/null && curl -sf "http://${ICECAST_HOST}:${ICECAST_PORT}/" -o /dev/null 2>/dev/null) || \
           (exec 3<>/dev/tcp/${ICECAST_HOST}/${ICECAST_PORT} 2>/dev/null); then
            log "✅  Icecast prêt"
            [[ -n "${AS_FD:-}" ]] && exec 3>&- # Close fd if opened
            break
        fi
        sleep 1
    done

    start_ffmpeg_streamer
    sleep 4 # Slightly longer wait for pipe initialization

    start_podcast_generation
    wait_for_generation_with_music
    log "✅  Prêt pour le prochain podcast"

    while true; do
        local wait_sec
        wait_sec=$(seconds_to_next_half_hour)
        log "⏰  Prochain podcast dans ${wait_sec}s"

        rm -f /tmp/podcast_trigger
        ( sleep "$wait_sec" && echo 1 > /tmp/podcast_trigger ) &
        TIMER_PID=$!

        while true; do
            play_next_track

            if [[ -f /tmp/podcast_trigger ]]; then
                log "⏰  C'est l'heure de la chronique !"
                rm -f /tmp/podcast_trigger
                break
            fi
        done

        kill "$TIMER_PID" 2>/dev/null || true
        TIMER_PID=""

        run_podcast
    done
}

cleanup() {
    log "🛑  Arrêt du service radio"
    [[ -n "${MUSIC_PID:-}"  ]] && kill "$MUSIC_PID"  2>/dev/null || true
    [[ -n "${TIMER_PID:-}"  ]] && kill "$TIMER_PID"  2>/dev/null || true
    [[ -n "${FFMPEG_PID:-}" ]] && kill "$FFMPEG_PID" 2>/dev/null || true
    [[ -n "${GEN_PID:-}"    ]] && kill "$GEN_PID"    2>/dev/null || true
    rm -f "$FIFO"
    exit 0
}
trap cleanup SIGTERM SIGINT

main
