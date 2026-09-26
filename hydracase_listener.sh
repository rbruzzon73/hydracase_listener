#!/usr/bin/env bash

# ==============================================================================
#
# hydracase_listener.sh Ver2.5 by rbruzzon@redhat.com
#
# ==============================================================================

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
DUMP_RAW_MESSAGES=true                # Set to 'true' to dump raw Slack JSON messages
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# TEST MODE CONFIGURATION (For use with send_mock_event.sh)
# ------------------------------------------------------------------------------
TEST_MODE=false                       # Set to 'true' to enable testing, 'false' for production
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
EOF
}

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
echo "[+] Debug Mode    : ${DEBUG_MODE} (Dump Credentials: ${SHOW_CREDENTIALS_DUMP} | Dump Raw MSG: ${DUMP_RAW_MESSAGES})"
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

            if [ "$DEBUG_MODE" = true ] && [ "$DUMP_RAW_MESSAGES" = true ]; then
                log_debug "=== RAW MESSAGE JSON DUMP ==="
                log_debug "$(echo "$msg" | jq . 2>/dev/null || echo "$msg")"
                log_debug "============================="
            fi

            ATTACH_COUNT=$(echo "$msg" | jq '.attachments | length // 0')

            if [ "$ATTACH_COUNT" -gt 0 ]; then
                for (( idx=0; idx<ATTACH_COUNT; idx++ )); do
                    ATT=$(echo "$msg" | jq -c ".attachments[$idx]")

                    # ----------------------------------------------------------
                    # ESTRAZIONE PARSER AVANZATA VIA PYTHON
                    # ----------------------------------------------------------
                    EVAL_OUT=$(python3 -c "
import json, html, re, sys

try:
    att = json.loads(sys.argv[1])
    
    # 1. Estrazione Titolo dal blocco Context o dal Fallback
    title = ''
    for block in att.get('blocks', []):
        if block.get('type') == 'context':
            for elem in block.get('elements', []):
                txt = elem.get('text', '')
                if not txt.startswith('id:'):
                    title = txt
                    break

    if not title and 'fallback' in att:
        fb_match = re.search(r'Subject:\s*(.*?)(?=\n|$)', att['fallback'])
        if fb_match:
            title = fb_match.group(1).strip()

    # 2. Decodifica testo completo dei Blocks
    full_text = ''
    for block in att.get('blocks', []):
        if 'text' in block and isinstance(block['text'], dict):
            full_text += block['text'].get('text', '') + '\n'
        if 'fields' in block:
            for f in block['fields']:
                full_text += f.get('text', '') + '\n'

    decoded = html.unescape(html.unescape(full_text))

    # 3. Estrazione dei singoli campi
    num_m = re.search(r':case_number:\s*([0-9]{7,8})', decoded)
    case_num = num_m.group(1).strip() if num_m else 'UnknownCase'

    cust_m = re.search(r':account:\s*(.*?)\s*(?=:case_owner:|:product:|:package:|:bust_in_silhouette:|\t|\n|$)', decoded)
    customer = cust_m.group(1).strip() if cust_m else 'Red Hat Account'

    owner_m = re.search(r':case_owner:\s*(.*?)\s*(?=:product:|:package:|\t|\n|$)', decoded)
    case_owner = owner_m.group(1).strip() if owner_m else 'Unassigned'

    # Se l'owner è una menzione ID (<@U...), estraiamo il nome dal fallback
    if case_owner.startswith('<@') and 'fallback' in att:
        owner_fb = re.search(r'Owner:\s*(.*?)(?=\n|$)', att['fallback'])
        if owner_fb:
            case_owner = owner_fb.group(1).strip()

    prod_m = re.search(r':product:\s*(.*?)\s*(?=\t|\n|$)', decoded)
    platform = prod_m.group(1).strip() if prod_m else 'Red Hat Enterprise Software'

    # Output per eval Bash
    print(f'CASE_NUM=\"{case_num}\"')
    print(f'CUSTOMER=\"{customer}\"')
    print(f'CASE_OWNER=\"{case_owner}\"')
    print(f'PLATFORM=\"{platform}\"')
    print(f'TITLE_CASE=\"{title}\"')

except Exception:
    print('CASE_NUM=\"UnknownCase\"')
    print('CUSTOMER=\"Red Hat Account\"')
    print('CASE_OWNER=\"Unassigned\"')
    print('PLATFORM=\"Red Hat Enterprise Software\"')
    print('TITLE_CASE=\"N/A\"')
" "$ATT")

                    # Assegna le variabili estratte da Python
                    eval "$EVAL_OUT"

                    # ----------------------------------------------------------
                    # COSTRUZIONE DEL BODY TEXT ETICHETTATO
                    # ----------------------------------------------------------
                    BODY_TEXT=$(python3 -c "
import json, html, re, sys

try:
    att = json.loads(sys.argv[1])
    
    extra_lines = []
    for block in att.get('blocks', []):
        btype = block.get('type')
        if btype == 'section' and 'text' in block:
            t = block['text'].get('text', '')
            if 'Status:' in t:
                extra_lines.append(t)
        elif 'fields' in block:
            for f in block['fields']:
                extra_lines.append(f.get('text', ''))

    extra_text = '\n'.join(extra_lines)
    extra_text = html.unescape(html.unescape(extra_text))
    extra_text = re.sub(r'[*~]', '', extra_text)

    body = f'''Case Number: ${CASE_NUM}
Title: ${TITLE_CASE}
Customer Name: ${CUSTOMER}
Case Owner: ${CASE_OWNER}
Platform: ${PLATFORM}
{extra_text}'''
    print(body.strip())
except Exception:
    print('Details Unavailable')
" "$ATT")

                    # Estrazione Severity, Status e SBT per l'oggetto Email
                    SEVERITY=$(echo "$BODY_TEXT" | grep -i 'Severity:' | sed 's/.*Severity:[[:space:]]*//I' | awk -F' ' '{print $1,$2}' | tr -d '\r')
                    [ -z "$SEVERITY" ] && SEVERITY="3 (Medium)"

                    STATUS=$(echo "$BODY_TEXT" | grep -i 'Status:' | head -n 1 | sed 's/.*Status:[[:space:]]*//I' | cut -d'*' -f1 | tr -d '\r')
                    [ -z "$STATUS" ] && STATUS="In Progress"

                    SBT=$(echo "$BODY_TEXT" | grep -i 'SBT:' | sed 's/.*SBT:[[:space:]]*//I' | tr -d '\r')
                    [ -z "$SBT" ] && SBT="N/A"

                    # Estrazione Link Portal & SFDC
                    PORTAL_URL=$(echo "$ATT" | jq -r '.. | .url? // empty' | grep -iE 'access.redhat.com|portal' | head -n 1)
                    SFDC_URL=$(echo "$ATT" | jq -r '.. | .url? // empty' | grep -iE 'force.com|salesforce|sfdc' | head -n 1)

                    [ -z "$PORTAL_URL" ] && [ "$CASE_NUM" != "UnknownCase" ] && PORTAL_URL="https://access.redhat.com/support/cases/#/case/${CASE_NUM}"
                    [ -z "$SFDC_URL" ] && SFDC_URL="https://redhat.lightning.force.com"

                    # Intestazione Email Estesa
                    EMAIL_TITLE="Severity: ${SEVERITY} - Status: ${STATUS} - SBT: ${SBT} - Case Number: ${CASE_NUM} - Platform: ${PLATFORM} - Customer: ${CUSTOMER}"
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
