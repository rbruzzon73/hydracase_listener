#!/usr/bin/env bash

# ==============================================================================
#
#  send_mock_event.sh Ver1.0 Sep 25, 2026 by rbruzzon@redhat.com
#
# ==============================================================================

# ==============================================================================
# CONFIGURATION & CONSTANTS
# ==============================================================================
TARGET_CHANNEL_ID="D04NRQ0PNJV" # Direct Message channel ID
CURRENT_USER="${USER:-$(whoami)}"

# Dynamic Firefox Profile Resolver
FF_BASE_DIR="/home/${CURRENT_USER}/.mozilla/firefox"
FF_PROFILE_DIR=$(find "$FF_BASE_DIR" -maxdepth 1 -type d \( -name "*RedHat*" -o -name "*.default*" -o -name "*.default-release*" \) 2>/dev/null | head -n 1)

FF_STORAGE_DB="${FF_PROFILE_DIR}/storage/default/https+++app.slack.com/ls/data.sqlite"
FF_COOKIES_DB="${FF_PROFILE_DIR}/cookies.sqlite"

# ==============================================================================
# HELP & CONFIGURATION GUIDE
# ==============================================================================
show_help() {
    cat << EOF
HydraCaseBot Mock Event Dispatcher

Usage:
  ./send_mock_event.sh [OPTION] [SCENARIO]

Options:
  -h, --help        Show this help menu and setup instructions
  -i, --interactive Interactively select scenario from a menu

Scenarios:
  1                 Send Scenario 1: Sogei S.p.A. (Waiting on Engineering)
  2                 Send Scenario 2: Robert Bosch GmbH (Waiting on Customer Action)
  both, all         Send both Scenario 1 and Scenario 2 sequentially

--------------------------------------------------------------------------------
CONFIGURATION & SETUP GUIDE
--------------------------------------------------------------------------------
1. Prerequisites:
   - Ensure 'jq', 'curl', 'sqlite3', and 'strings' are installed on your host:
       $ sudo dnf install -y jq curl sqlite coreutils

2. Dynamic Firefox Credentials:
   - Make sure Firefox is open and logged into Red Hat Slack.
   - Active User    : ${CURRENT_USER}
   - Resolved Profile: ${FF_PROFILE_DIR:-"Not Found"}
   - Storage Path   : ${FF_STORAGE_DB}

3. Script Variables (Inside send_mock_event.sh):
   - TARGET_CHANNEL_ID : Set to your target Slack DM/Channel ID (Default: "${TARGET_CHANNEL_ID}")
   - CURRENT_USER      : Automatically resolves active Linux user (\$USER -> "${CURRENT_USER}")

4. Testing Flow with Listener:
   a) Ensure TEST_MODE=true in 'hydracase_listener.sh'.
   b) Run 'hydracase_listener.sh' in one terminal window.
   c) Run 'send_mock_event.sh 1' or 'send_mock_event.sh 2' in another terminal.
--------------------------------------------------------------------------------

Examples:
  ./send_mock_event.sh 1          # Send scenario 1 (default)
  ./send_mock_event.sh 2          # Send scenario 2
  ./send_mock_event.sh both       # Send both scenarios
  ./send_mock_event.sh -i         # Run in interactive mode
  ./send_mock_event.sh --help     # Display this guide
EOF
}

# Check for help flags
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# ==============================================================================
# INTERACTIVE MODE
# ==============================================================================
if [[ "$1" == "-i" ]] || [[ "$1" == "--interactive" ]]; then
    echo "=================================================="
    echo "  HydraCaseBot Interactive Event Simulator"
    echo "=================================================="
    echo "Target Channel: ${TARGET_CHANNEL_ID}"
    echo "Active User   : ${CURRENT_USER}"
    echo "Profile Dir   : ${FF_PROFILE_DIR}"
    echo "--------------------------------------------------"
    echo "Select a scenario to send to Slack:"
    echo "  1) Scenario 1: Sogei S.p.A. (Waiting on Engineering)"
    echo "  2) Scenario 2: Robert Bosch GmbH (Waiting on Customer Action)"
    echo "  3) Both Scenarios (Sequential)"
    echo "  q) Quit"
    echo "=================================================="
    read -rp "Enter choice [1-3]: " CHOICE
    case "$CHOICE" in
        1) SCENARIO_ARG="1" ;;
        2) SCENARIO_ARG="2" ;;
        3) SCENARIO_ARG="both" ;;
        *) echo "Exiting."; exit 0 ;;
    esac
else
    SCENARIO_ARG="${1:-1}"
fi

# ==============================================================================
# CREDENTIAL EXTRACTION HELPERS
# ==============================================================================
get_slack_token() {
    [ -f "$FF_STORAGE_DB" ] || return
    cp "$FF_STORAGE_DB"* /tmp/ 2>/dev/null
    local token
    token=$(strings /tmp/data.sqlite 2>/dev/null | grep -o 'xoxc-[0-9a-zA-Z-]*' | head -n 1)
    rm -f /tmp/data.sqlite* 2>/dev/null
    echo "$token"
}

get_slack_cookie() {
    [ -f "$FF_COOKIES_DB" ] || return
    cp "$FF_COOKIES_DB"* /tmp/ 2>/dev/null
    local cookie
    if command -v sqlite3 &>/dev/null; then
        cookie=$(sqlite3 /tmp/cookies.sqlite \
            "SELECT value FROM moz_cookies WHERE host LIKE '%slack.com%' AND name='d';" 2>/dev/null)
    fi
    if [ -z "$cookie" ]; then
        cookie=$(strings /tmp/cookies.sqlite 2>/dev/null | grep -oE 'xoxd-[0-9a-zA-Z%=-]+' | head -n 1)
    fi
    rm -f /tmp/cookies.sqlite* 2>/dev/null
    echo "$cookie"
}

# Extract Active Credentials
SLACK_USER_TOKEN=$(get_slack_token)
SLACK_COOKIE_D=$(get_slack_cookie)

if [ -z "$SLACK_USER_TOKEN" ] || [ -z "$SLACK_COOKIE_D" ]; then
    echo "[-] Error: Could not extract active Slack credentials from Firefox profile: ${FF_PROFILE_DIR}"
    echo "    Ensure Firefox is running and logged into Red Hat Slack under user '${CURRENT_USER}'."
    exit 1
fi

echo "[+] Authenticated user '${CURRENT_USER}' with active session token."

# ==============================================================================
# EVENT DISPATCH FUNCTION
# ==============================================================================
send_scenario() {
    local scenario_num="$1"
    local pretext text color

    if [ "$scenario_num" -eq 1 ]; then
        echo "[+] Sending Mock Scenario 1: Sogei S.p.A. (Waiting on Engineering)"
        pretext="🟡 my Customers - TS WoEng | Case Updated: #04532751 | Status"
        color="#ECB22E"
        text=$':briefcase: 04532751  :building_construction: Sogei S.p.A.  :bust_in_silhouette: @fcardoso  :package: OpenShift Container Platform 4.20\n\n[OCP1V] OCP 4.20 Console Topology crashes after update from OCP 4.18\n\n*Status: ~Waiting on Customer Action Required~ -> Waiting on Engineering*\n\n*Severity:* 4 (Low)                 *SBR:* Shift\n*Status:* Waiting on Engineering       *SBT:* Breaching in 959 min'
    else
        echo "[+] Sending Mock Scenario 2: Robert Bosch GmbH (Waiting on Customer Action)"
        pretext="🟡 my Customers - TS CActionReq | Case Updated: #07771969 | Status"
        color="#2EB886"
        text=$':briefcase: 07771969  :building_construction: Robert Bosch GmbH  :bust_in_silhouette: @Anas  :package: OpenShift Container Platform 4.20\n\nWebconsole reference to private Helm repository not working\n\n*Status: ~In Progress~ -> Waiting on Customer Action Required*\n\n*Severity:* 3 (Medium)               *SBR:* Shift - Devops\n*Status:* Waiting on Customer Action Required'
    fi

    local payload
    payload=$(jq -n \
      --arg channel "$TARGET_CHANNEL_ID" \
      --arg pretext "$pretext" \
      --arg text "$text" \
      --arg color "$color" \
      '{
        channel: $channel,
        as_user: true,
        attachments: [{
          pretext: $pretext,
          text: $text,
          color: $color,
          mrkdwn_in: ["text", "pretext"],
          actions: [
            { type: "button", text: "🔴 Portal", url: "https://access.redhat.com" },
            { type: "button", text: "☁️ SFDC", url: "https://redhat.lightning.force.com" }
          ]
        }]
      }')

    local response ok ts err
    response=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
        -H "Cookie: d=${SLACK_COOKIE_D}" \
        -H "Content-Type: application/json; charset=utf-8" \
        --data "$payload")

    ok=$(echo "$response" | jq -r '.ok // false')

    if [ "$ok" == "true" ]; then
        ts=$(echo "$response" | jq -r '.ts')
        echo "[+] Scenario $scenario_num posted successfully with timestamp $ts"
    else
        err=$(echo "$response" | jq -r '.error // "Unknown error"')
        echo "[-] Scenario $scenario_num failed: $err"
    fi
}

# ==============================================================================
# MAIN EXECUTION ROUTER
# ==============================================================================
case "$SCENARIO_ARG" in
    1)
        send_scenario 1
        ;;
    2)
        send_scenario 2
        ;;
    both|all)
        send_scenario 1
        sleep 2
        send_scenario 2
        ;;
    *)
        echo "[-] Invalid scenario choice: '$SCENARIO_ARG'"
        echo "    Run './send_mock_event.sh --help' for usage and setup instructions."
        exit 1
        ;;
esac
