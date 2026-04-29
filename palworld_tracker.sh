#!/bin/bash

# --- CONFIGURATION ---
MSG_ID_FILE="discord_message_id.txt"
BOT_NAME="Skye Serve Palworld Monitor"
BOT_LOGO="https://raw.githubusercontent.com/parkervcp/pterodactyl-images/master/logos/palworld.png"

# --- GHOST KILLER ---
for pid in $(pgrep -f palworld_tracker.sh); do
    if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
        kill -9 "$pid" 2>/dev/null
    fi
done

# CLEAN RESET
rm -f "payload.json"
rm -f "$MSG_ID_FILE"

echo "--- Palworld RCON Tracker Started: $(date) ---" > tracker_debug.log

# ========================================================
# --- INFO EXTRACTOR ---
# ========================================================
get_server_info() {
    # Palworld uses the variable SERVER_NAME usually, but fallback if empty
    CLEAN_SNAME="${SERVER_NAME:-Skye Serve Hosted Palworld}"
    # Strip any weird characters just in case
    CLEAN_SNAME=$(echo "$CLEAN_SNAME" | tr -d '"' | tr -d "'" | tr -dc '[:print:]')
}

# ========================================================
# --- SHUTDOWN INTERCEPTOR ---
# ========================================================
send_offline() {
    CUR_TIME=$(date +'%T')
    get_server_info
    cat <<EOF > payload.json
{
  "username": "$BOT_NAME",
  "avatar_url": "$BOT_LOGO",
  "embeds": [{
    "title": "🪐 Palworld Live Server Status",
    "color": 15548997, 
    "fields": [
      {"name": "Server Name", "value": "$CLEAN_SNAME", "inline": true},
      {"name": "Status", "value": "🔴 Offline", "inline": true},
      {"name": "Online Players", "value": "\`\`\`\nServer is currently offline\n\`\`\`", "inline": false}
    ],
    "footer": {"text": "Last Updated: $CUR_TIME | Skye Serve"}
  }]
}
EOF
    if [ -s "$MSG_ID_FILE" ]; then
        MESSAGE_ID=$(cat "$MSG_ID_FILE")
        curl -s -o /dev/null -X PATCH -H "Content-Type: application/json" -d @payload.json "${DISCORD_WEBHOOK}/messages/${MESSAGE_ID}"
    fi
    exit 0
}
trap send_offline SIGTERM SIGINT

# ========================================================
# --- MAIN DISCORD LOOP (RCON Polling) ---
# ========================================================
while true; do
    CUR_TIME=$(date +'%T')
    get_server_info

    # 1. Ask the server who is online
    # Using timeout to prevent the script from hanging if RCON is unresponsive
    RAW_PLAYERS=$(timeout 3 rcon -t rcon -a 127.0.0.1:${RCON_PORT} -p "${ADMIN_PASSWORD}" ShowPlayers 2>/dev/null)
    
    # 2. Check if the server responded
    if [[ -z "$RAW_PLAYERS" ]] || [[ "$RAW_PLAYERS" == *"Unknown command"* ]] || [[ "$RAW_PLAYERS" == *"refused"* ]]; then
        STATUS="🟡 Starting / Offline"
        COLOR=16766720
        PLAYERS=0
        FINAL_LIST="Waiting for server..."
    else
        STATUS="🟢 Online"
        COLOR=5763719
        
        # Palworld outputs a header: name,playeruid,steamid
        # We delete the 1st line (header), split by commas, and grab the names
        CLEAN_PLAYERS=$(echo "$RAW_PLAYERS" | sed '1d' | tr -d '\r' | awk -F',' '{print $1}' | sed '/^$/d')
        
        # Count the players
        PLAYERS=$(echo "$CLEAN_PLAYERS" | grep -c "[^[:space:]]")
        
        if [ "$PLAYERS" -eq 0 ]; then
            FINAL_LIST="None online"
        else
            # Format the list for Discord (Player1\nPlayer2\nPlayer3)
            FINAL_LIST=$(echo "$CLEAN_PLAYERS" | paste -sd ',' - | sed 's/,/\\n/g')
        fi
    fi

    cat <<EOF > payload.json
{
  "username": "$BOT_NAME",
  "avatar_url": "$BOT_LOGO",
  "embeds": [{
    "title": "🪐 Palworld Live Server Status",
    "color": $COLOR,
    "fields": [
      {"name": "Server Name", "value": "$CLEAN_SNAME", "inline": true},
      {"name": "Status", "value": "$STATUS", "inline": true},
      {"name": "Current Players", "value": "$PLAYERS", "inline": true},
      {"name": "Online Players", "value": "\`\`\`\n$FINAL_LIST\n\`\`\`", "inline": false}
    ],
    "footer": {"text": "Last Updated: $CUR_TIME | Skye Serve"}
  }]
}
EOF

    if [ ! -s "$MSG_ID_FILE" ]; then
        RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d @payload.json "${DISCORD_WEBHOOK}?wait=true")
        NEW_ID=$(echo "$RESPONSE" | grep -o '"id":"[0-9]*"' | head -n 1 | cut -d'"' -f4)
        if [[ "$NEW_ID" =~ ^[0-9]+$ ]]; then echo "$NEW_ID" > "$MSG_ID_FILE"; fi
    else
        MESSAGE_ID=$(cat "$MSG_ID_FILE")
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH -H "Content-Type: application/json" -d @payload.json "${DISCORD_WEBHOOK}/messages/${MESSAGE_ID}")
        if [ "$HTTP_CODE" == "404" ]; then rm -f "$MSG_ID_FILE"; fi
    fi
    
    # Poll every 10 seconds (don't spam RCON too aggressively)
    sleep 10 &
    wait $!
done
