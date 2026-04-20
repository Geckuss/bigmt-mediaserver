#!/bin/bash

# Sonarr passes the file path as environment variables
# Sonarr: $sonarr_episodefile_path
# Radarr: $radarr_moviefile_path
FILE="${sonarr_episodefile_path:-$radarr_moviefile_path}"

if [ -z "$FILE" ]; then
    echo "No file path provided"
    exit 0
fi

# Get subtitle stream info as json for reliable parsing
STREAMS=$(ffprobe -v quiet -select_streams s -show_entries stream=index,codec_name:stream_tags=language -of json "$FILE" 2>/dev/null)

if [ -z "$STREAMS" ]; then
    echo "No subtitle streams found"
    exit 0
fi

# Check if there are any streams
STREAM_COUNT=$(echo "$STREAMS" | grep -c '"index"')

if [ "$STREAM_COUNT" -eq 0 ]; then
    echo "No subtitle streams found"
    exit 0
fi

BASENAME="${FILE%.*}"
COUNTER=0

# Parse each stream using grep/sed (available on alpine)
INDEXES=$(echo "$STREAMS" | grep '"index"' | sed 's/[^0-9]//g')
CODECS=$(echo "$STREAMS" | grep '"codec_name"' | sed 's/.*: "//;s/".*//')
LANGS=$(echo "$STREAMS" | grep '"language"' | sed 's/.*: "//;s/".*//')

# Convert to arrays
readarray -t INDEX_ARR <<< "$INDEXES"
readarray -t CODEC_ARR <<< "$CODECS"
readarray -t LANG_ARR <<< "$LANGS"

for i in "${!INDEX_ARR[@]}"; do
    INDEX="${INDEX_ARR[$i]}"
    CODEC="${CODEC_ARR[$i]}"
    LANG="${LANG_ARR[$i]:-und}"

    # Only process ASS/SSA subtitles
    if [[ "$CODEC" == "ass" || "$CODEC" == "ssa" ]]; then
        # Build output filename
        if [ $COUNTER -eq 0 ]; then
            OUTFILE="${BASENAME}.${LANG}.srt"
        else
            OUTFILE="${BASENAME}.${LANG}.${COUNTER}.srt"
        fi

        # Skip if SRT already exists
        if [ ! -f "$OUTFILE" ]; then
            echo "Extracting stream $INDEX ($CODEC, $LANG) -> $OUTFILE"
            ffmpeg -v quiet -i "$FILE" -map "0:${INDEX}" -c:s srt "$OUTFILE" -y
        else
            echo "Skipping stream $INDEX ($LANG) - SRT already exists"
        fi

        COUNTER=$((COUNTER + 1))
    fi
done

echo "Done. Extracted $COUNTER subtitle(s)."
exit 0
