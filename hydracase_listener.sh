#!/usr/bin/env bash

# ==============================================================================
# CONFIGURATION & CONSTANTS
# ==============================================================================
TARGET_CHANNEL_ID="D04NRQ0PNJV"       # Direct Message channel with HydraCaseBot
BOT_USER_ID="U04JNCVBVNU"             # HydraCaseBot User ID
CURRENT_USER="${USER:-$(whoami)}"
TARGET_EMAIL="${CURRENT_USER}@redhat.com" # Auto-resolves current Linux user email
SMTP_SERVER="smtp.corp.redhat.com:25" # Internal SMTP Relay Server
POLL_INTERVAL=15                      # Polling Interval (in seconds)
LAST_SEEN_FILE="/tmp/hydracase_last_seen_${CURRENT_USER}.txt"

# ------------------------------------------------------------------------------
# LOGGING & DEBUG CONFIGURATION
# ------------------------------------------------------------------------------
DEBUG_MODE=true                       # Set to 'true' for verbose execution logs
SHOW_CREDENTIALS_DUMP=false           # Set to 'false' to hide raw TOKEN & COOKIE strings
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# TEST MODE CONFIGURATION (For use with send_mock_event.sh)
# ------------------------------------------------------------------------------
TEST_MODE=true                        # Set to 'true' to enable testing, 'false' for production
TEST_USER_ID="U02P7NU7T8W"            # Personal Slack User ID for test message interception
# ------------------------------------------------------------------------------

# Dynamic Firefox Profile Resolver
FF_BASE_DIR="/home/${CURRENT_USER}/.mozilla/firefox"
FF_PROFILE_DIR=$(find "$FF_BASE_DIR" -maxdepth 1 -type d \( -name "*RedHat*" -o -name "*.default*" -o -name "*.default-release*" \) 2>/dev/null | head -n 1)

FF_STORAGE_DB="${FF_PROFILE_DIR}/storage/default/https+++app.slack.com/ls/data.sqlite"

# Logging Helpers
log_debug() { [ "$DEBUG_MODE" = true ] && echo -e "[\e[34mDEBUG\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_success() { echo -e "[\e[32mOK\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo -e "[\e[33mWARN\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo -e "[\e[31mERROR\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# ==============================================================================
# HELP & SETUP GUIDE
# ==============================================================================
show_help() {
    cat << EOF
HydraCaseBot Slack-to-Email Listener Service

Usage:
  ./hydracase_listener.sh [OPTION]

Options:
  -h, --help        Show this help menu and setup instructions

--------------------------------------------------------------------------------
CONFIGURATION & SETUP GUIDE
--------------------------------------------------------------------------------
1. Prerequisites & Dependencies:
   - Ensure 'jq', 'curl', 'sqlite3', 's-nail' (mailx), and Python packages are installed:
       $ sudo dnf install -y jq curl sqlite coreutils s-nail xdotool python3-pip
       $ pip install browser-cookie3 --user

2. DEBUG & CREDENTIAL LOGGING CONTROL:
   - DEBUG_MODE=true|false             : Enables or disables general debug logging.
   - SHOW_CREDENTIALS_DUMP=true|false  : Set to 'false' to hide raw TOKEN and COOKIE
                                         dumps from terminal output while keeping
                                         operational debug logs visible.

3. TEST MODE CONFIGURATION:
   - TEST_MODE=true  : Listens for BOTH HydraCaseBot AND your TEST_USER_ID.
                       Appends '[TEST]' to email subject lines.
   - TEST_MODE=false : Production mode. Intercepts ONLY official HydraCaseBot alerts.

4. AUTOMATED RENEWAL & SELF-HEALING:
   - Uses 'browser_cookie3' to dynamically extract the 'd' cookie with %2B URL encoding.
   - If session expires, 'refresh_firefox_session' reloads the Slack tab via 'xdotool' or CLI.

5. Running the Service:
   - Standard execution:
       $ ./hydracase_listener.sh
   - Running in background:
       $ nohup ./hydracase_listener.sh > /tmp/hydracase.log 2>&1 &
--------------------------------------------------------------------------------
EOF
}

# Check for help flags
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# ==============================================================================
# CREDENTIAL EXTRACTION & SELF-HEALING
# ==============================================================================
sync_firefox_wal() {
    if command -v sqlite3 &>/dev/null; then
        sqlite3 "$FF_STORAGE_DB" "PRAGMA wal_checkpoint(FULL);" 2>/dev/null
    fi
}

refresh_firefox_session() {
    log_warn "Triggering Automated Self-Healing Mechanism..."
    sync_firefox_wal

    if command -v xdotool &>/dev/null && [ -n "$DISPLAY" ]; then
        log_debug "Sending reload shortcut (Ctrl+Shift+R) to Firefox via xdotool..."
        xdotool search --onlyvisible --class firefox windowactivate --sync key Ctrl+Shift+r 2>/dev/null
    elif command -v firefox &>/dev/null; then
        log_debug "Pinging Slack tab in Firefox..."
        firefox "https://app.slack.com/client" 2>/dev/null &
    fi
}

get_slack_token() {
    sync_firefox_wal
    [ -f "$FF_STORAGE_DB" ] || return

    cp "$FF_STORAGE_DB"* /tmp/ 2>/dev/null
    local extracted_token
    extracted_token=$(strings /tmp/data.sqlite* 2>/dev/null | grep -oE 'xoxc-[0-9a-zA-Z-]{80,}' | tail -n 1)
    rm -f /tmp/data.sqlite* 2>/dev/null
    echo "$extracted_token"
}

get_slack_cookie() {
    python3 -c "
import browser_cookie3, urllib.parse

try:
    cj = browser_cookie3.firefox(domain_name='.slack.com')
    raw_d = [c.value for c in cj if c.name == 'd'][0]
    
    if '+' in raw_d or '/' in raw_d:
        print(urllib.parse.quote(raw_d))
    else:
        print(raw_d)
except Exception:
    pass
" 2>/dev/null
}

verify_slack_token() {
    local token="$1"
    local cookie="$2"
    
    log_debug "Executing auth.test verification against Slack API..."
    local auth_response
    auth_response=$(curl -s -X POST "https://slack.com/api/auth.test" \
        -H "Authorization: Bearer ${token}" \
        -H "Cookie: d=${cookie}" \
        -H "Content-Type: application/x-www-form-urlencoded")

    local is_ok
    is_ok=$(echo "$auth_response" | jq -r '.ok // false')

    if [ "$is_ok" == "true" ]; then
        log_success "Authentication valid for active user!"
        return 0
    else
        log_error "Auth failed: $(echo "$auth_response" | jq -r '.error // "invalid_auth"')"
        log_debug "FULL Auth Response: $auth_response"
        return 1
    fi
}

# ==============================================================================
# MAIN LOOP
# ==============================================================================
echo "=================================================="
echo "[+] Starting HydraCaseBot Dynamic Listener"
echo "[+] Active User   : ${CURRENT_USER}"
echo "[+] Target Email  : ${TARGET_EMAIL}"
echo "[+] Firefox Profile: ${FF_PROFILE_DIR}"
echo "[+] Debug Mode    : ${DEBUG_MODE} (Show Dump: ${SHOW_CREDENTIALS_DUMP})"
if [ "$TEST_MODE" = true ]; then
    echo -e "[\e[33mTEST MODE ENABLED\e[0m] Intercepting Bot ($BOT_USER_ID) AND Test User ($TEST_USER_ID)"
fi
echo "=================================================="

[ -f "$LAST_SEEN_FILE" ] || echo "0" > "$LAST_SEEN_FILE"

while true; do
    log_debug "--------------------------------------------------"
    log_debug "Starting polling loop..."

    SLACK_USER_TOKEN=$(get_slack_token)
    SLACK_COOKIE_D=$(get_slack_cookie)

    # --------------------------------------------------------------------------
    # FULL CREDENTIALS DEBUG DUMP (CONDITIONAL)
    # --------------------------------------------------------------------------
    if [ "$DEBUG_MODE" = true ] && [ "$SHOW_CREDENTIALS_DUMP" = true ]; then
        log_debug "=== FULL CREDENTIALS DUMP ==="
        log_debug "TOKEN (Len ${#SLACK_USER_TOKEN})  : ${SLACK_USER_TOKEN:-"NOT FOUND"}"
        log_debug "COOKIE (Len ${#SLACK_COOKIE_D}) : ${SLACK_COOKIE_D:-"NOT FOUND"}"
        log_debug "============================="
    fi

    if [ -z "$SLACK_USER_TOKEN" ] || [ -z "$SLACK_COOKIE_D" ]; then
        log_error "Missing credentials. Token: ${#SLACK_USER_TOKEN} chars, Cookie: ${#SLACK_COOKIE_D} chars"
        refresh_firefox_session
        sleep "$POLL_INTERVAL"
        continue
    fi

    verify_slack_token "$SLACK_USER_TOKEN" "$SLACK_COOKIE_D" || {
        log_error "Session validation rejected by Slack."
        refresh_firefox_session
        sleep "$POLL_INTERVAL"
        continue
    }

    LAST_SEEN=$(cat "$LAST_SEEN_FILE")

    RESPONSE=$(curl -s -X GET "https://slack.com/api/conversations.history?channel=${TARGET_CHANNEL_ID}&limit=10" \
        -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
        -H "Cookie: d=${SLACK_COOKIE_D}" \
        -H "Content-Type: application/x-www-form-urlencoded")

    OK_STATUS=$(echo "$RESPONSE" | jq -r '.ok // false')
    if [ "$OK_STATUS" != "true" ]; then
        log_error "Slack API Error: $(echo "$RESPONSE" | jq -r '.error // "Unknown"')"
        refresh_firefox_session
        sleep "$POLL_INTERVAL"
        continue
    fi

    if [ "$TEST_MODE" = true ]; then
        MESSAGES=$(echo "$RESPONSE" | jq -c --arg bot_id "$BOT_USER_ID" --arg test_id "$TEST_USER_ID" --arg last_ts "$LAST_SEEN" \
            '[.messages[]? | select((.user == $bot_id or .user == $test_id or .bot_id != null) and (.ts > $last_ts))] | reverse | .[]')
    else
        MESSAGES=$(echo "$RESPONSE" | jq -c --arg bot_id "$BOT_USER_ID" --arg last_ts "$LAST_SEEN" \
            '[.messages[]? | select((.user == $bot_id or .bot_id != null) and (.ts > $last_ts))] | reverse | .[]')
    fi

    if [ -n "$MESSAGES" ]; then
        while IFS= read -r msg; do
            [ -z "$msg" ] && continue
            
            TS=$(echo "$msg" | jq -r '.ts')
            EPOCH_SEC=$(echo "$TS" | cut -d'.' -f1)
            HUMAN_TS=$(date -d "@${EPOCH_SEC}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$TS")

            SENDER=$(echo "$msg" | jq -r '.user // "bot"')
            log_debug "Processing message TS: $TS ($HUMAN_TS) [Sender: $SENDER]"

            ATTACH_COUNT=$(echo "$msg" | jq '.attachments | length // 0')

            if [ "$ATTACH_COUNT" -gt 0 ]; then
                for (( idx=0; idx<ATTACH_COUNT; idx++ )); do
                    ATT=$(echo "$msg" | jq -c ".attachments[$idx]")

                    RAW_TEXT=$(echo "$ATT" | jq -r '
                        if .text then .text
                        elif .fallback then .fallback
                        else (.blocks[]? | .text.text? // .elements[]?.text? // empty)
                        end
                    ')

                    BODY_TEXT=$(echo "$RAW_TEXT" | sed \
                        -e 's/\\n/\n/g' \
                        -e 's/-&gt;/->/g' \
                        -e 's/&gt;/>/g' \
                        -e 's/&lt;/</g' \
                        -e 's/&amp;/&/g' \
                        -e 's/:briefcase:/💼/g' \
                        -e 's/:building_construction:/🏗️/g' \
                        -e 's/:bust_in_silhouette:/👤/g' \
                        -e 's/:package:/📦/g' \
                        -e 's/[*~]//g')

                    CASE_NUM=$(echo "$BODY_TEXT" | grep -oE '[0-9]{7,8}' | head -n 1)
                    [ -z "$CASE_NUM" ] && CASE_NUM="UnknownCase"

                    CUSTOMER=$(echo "$BODY_TEXT" | grep -oE '(🏗️|:building_construction:)[^👤@\n]+' | sed -e 's/🏗️//g' -e 's/:building_construction://g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | head -n 1)
                    [ -z "$CUSTOMER" ] && CUSTOMER=$(echo "$BODY_TEXT" | grep -oE '(BANCA[^\n|👤@]*|Robert Bosch[^\n|👤@]*|Sogei[^\n|👤@]*|GmbH|S\.p\.A\.)' | head -n 1 | sed 's/[[:space:]]*$//')
                    [ -z "$CUSTOMER" ] && CUSTOMER="Red Hat Account"

                    SEVERITY=$(echo "$BODY_TEXT" | grep -i 'Severity:' | sed 's/.*Severity:[[:space:]]*//I' | awk -F' ' '{print $1,$2}' | tr -d '\r')
                    [ -z "$SEVERITY" ] && SEVERITY="3 (Medium)"

                    STATUS=$(echo "$BODY_TEXT" | grep -i 'Status:' | head -n 1 | sed 's/.*Status:[[:space:]]*//I' | cut -d'*' -f1 | tr -d '\r')
                    [ -z "$STATUS" ] && STATUS="In Progress"

                    SBT=$(echo "$BODY_TEXT" | grep -i 'SBT:' | sed 's/.*SBT:[[:space:]]*//I' | tr -d '\r')
                    [ -z "$SBT" ] && SBT="N/A"

                    PORTAL_URL=$(echo "$ATT" | jq -r '.. | .url? // empty' | grep -iE 'access.redhat.com|portal' | head -n 1)
                    SFDC_URL=$(echo "$ATT" | jq -r '.. | .url? // empty' | grep -iE 'force.com|salesforce|sfdc' | head -n 1)

                    [ -z "$PORTAL_URL" ] && [ "$CASE_NUM" != "UnknownCase" ] && PORTAL_URL="https://access.redhat.com/support/cases/#/case/${CASE_NUM}"
                    [ -z "$SFDC_URL" ] && SFDC_URL="https://redhat.lightning.force.com"

                    EMAIL_TITLE="Severity: ${SEVERITY} - Status: ${STATUS} - SBT: ${SBT} - Case Number: ${CASE_NUM} - Customer: ${CUSTOMER}"
                    [ "$TEST_MODE" = true ] && EMAIL_TITLE="[TEST] ${EMAIL_TITLE}"

                    log_debug "Dispatching card $((idx+1))/$ATTACH_COUNT to $TARGET_EMAIL with Title: $EMAIL_TITLE"

                    echo -e "HydraCaseBot Notification\n\nFull Details:\n----------------------------------------\n${BODY_TEXT}\n----------------------------------------\nDirect Links:\n🔴 Red Hat Portal: ${PORTAL_URL}\n☁️ Salesforce (SFDC): ${SFDC_URL}\n----------------------------------------\nDate/Time: ${HUMAN_TS}\nChannel: ${TARGET_CHANNEL_ID}" | \
                    mailx -S v15-compat=yes \
                          -S smtp-auth=none \
                          -S smtp-use-starttls=no \
                          -r "$TARGET_EMAIL" \
                          -s "$EMAIL_TITLE" \
                          -S mta="smtp://${SMTP_SERVER}" \
                          "$TARGET_EMAIL"

                    [ $? -eq 0 ] && log_success "Card $((idx+1)) dispatched!" || log_error "Failed to send card $((idx+1))"
                done
            else
                PLAIN_TEXT=$(echo "$msg" | jq -r '.text' | sed -e 's/-&gt;/->/g' -e 's/&amp;/&/g')
                EMAIL_TITLE="Hydra Notification - TS: $HUMAN_TS"
                [ "$TEST_MODE" = true ] && EMAIL_TITLE="[TEST] ${EMAIL_TITLE}"

                echo -e "HydraCaseBot Notification\n\nContent:\n----------------------------------------\n${PLAIN_TEXT}\n----------------------------------------\nDate/Time: ${HUMAN_TS}" | \
                mailx -S v15-compat=yes \
                      -S smtp-auth=none \
                      -S smtp-use-starttls=no \
                      -r "$TARGET_EMAIL" \
                      -s "$EMAIL_TITLE" \
                      -S mta="smtp://${SMTP_SERVER}" \
                      "$TARGET_EMAIL"
            fi

            echo "$TS" > "$LAST_SEEN_FILE"
            log_debug "Updated $LAST_SEEN_FILE with timestamp $TS"

        done < <(echo "$MESSAGES")
    fi

    log_debug "Sleeping for $POLL_INTERVAL seconds..."
    sleep "$POLL_INTERVAL"
done
