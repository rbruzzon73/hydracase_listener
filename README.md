# HydraCaseBot Slack Email Relay

Automated Bash tooling to intercept, sanitize, and forward Red Hat **HydraCaseBot** case update notifications from Slack to internal email via local SMTP relay.

---

## Features

- **Automated Authentication**: Seamlessly extracts active Slack Web API session tokens (`xoxc-`) and session cookies (`d=xoxd-...`) directly from modern Firefox SQLite databases without needing fixed OAuth app tokens.
- **Dynamic User & Profile Resolution**: Works out-of-the-box for any Linux user account (`$USER`) by dynamically discovering active Firefox profile directories (`*.default`, `RedHat.default`, `*.default-release`).
- **Clean Subject & Body Processing**: Strips raw Slack markdown, HTML entities (`-&gt;`), raw JSON keys, and assigned user mentions (`@user`) to build clean, standardized email subjects and bodies.
- **Multi-Card Splitting**: Unpacks Slack messages containing multiple attachment cards and forwards each notification as an individual, distinct email.
- **Pre-Send Verification**: Executes pre-flight `auth.test` API validation before dispatching mail to ensure active session credentials.
- **Embedded Test Harness**: Built-in mock event simulator (`send_mock_event.sh`) with an interactive menu to test full end-to-end delivery without waiting for live production traffic.

---

## File Structure

```text
.
├── hydracase_listener.sh  # Real-time polling service & email relay engine
├── send_mock_event.sh     # Interactive mock event dispatcher for local testing
└── README.md              # Project documentation
```

## Script Descriptions

### 1. `hydracase_listener.sh`
The primary background daemon that polls Slack for new `HydraCaseBot` notifications, converts the payload into structured metadata, and dispatches formatted emails.

* **Key Variables**:
  * `TARGET_CHANNEL_ID`: The Direct Message channel ID with `HydraCaseBot` (e.g., `D04NRQ0PNJV`).
  * `BOT_USER_ID`: The `HydraCaseBot` Member ID (e.g., `U04JNCVBVNU`).
  * `TEST_MODE`: When `true`, intercepts test messages sent by your personal user account (`TEST_USER_ID`) in addition to bot alerts and appends `[TEST]` to email titles.
  * `SMTP_SERVER`: Internal relay endpoint (`smtp.corp.redhat.com:25`).

### 2. `send_mock_event.sh`
An interactive event generator that simulates real `HydraCaseBot` Slack notifications. It posts mock payloads to the target Slack channel using your active Firefox session to validate listener parsing and email delivery.

* **Supported Scenarios**:
  * **Scenario 1**: High-priority update (`Sogei S.p.A.` - *Waiting on Engineering*).
  * **Scenario 2**: Medium-priority update (`Robert Bosch GmbH` - *Waiting on Customer Action*).
  * **Both**: Dispatches both scenarios sequentially.

---

## Finding Slack IDs (UI Guide)

To configure `TARGET_CHANNEL_ID` and `BOT_USER_ID`:
1. In the Slack client/browser, right-click the **HydraCaseBot** icon in your left sidebar.
2. Select **App details** $\rightarrow$ **View app details**.
3. Under the **About** tab, copy:
   - **Member ID** (e.g., `U04JNCVBVNU`) $\rightarrow$ Assign to `BOT_USER_ID`
   - **Channel ID** (e.g., `D04NRQ0PNJV`) $\rightarrow$ Assign to `TARGET_CHANNEL_ID`

---

## Prerequisites

Ensure all required command-line utilities are installed on your system:

```bash
sudo dnf install -y jq curl sqlite coreutils s-nail
pip install browser-cookie3 --user
```
- **Note: Firefox must be open and authenticated to Red Hat Slack so session tokens can be read from SQLite.**


## Quick Start & Usage Guide

### 1. Make Scripts Executable
```bash
chmod +x hydracase_listener.sh send_mock_event.sh
```

### 2. Run the Listener Service
- To start the listener in standard foreground mode:
```Bash
./hydracase_listener.sh
```

- To run as a continuous background daemon:
```Bash
nohup ./hydracase_listener.sh > /tmp/hydracase.log 2>&1 &
```

### 3. Test Delivery with Mock Events
- In a separate terminal window, trigger test notifications:

```Bash
# View help and configuration guide
./send_mock_event.sh --help
```
```Bash
# Run in interactive selection mode
./send_mock_event.sh -i
```
```Bash
# Send Scenario 1 directly
./send_mock_event.sh 1
```
```Bash
# Send Scenario 2 directly
./send_mock_event.sh 2
```
```Bash
# Send all scenarios sequentially
./send_mock_event.sh both
```

## Production Deployment Checklist
- When moving from testing to live production execution:
   - Open hydracase_listener.sh.
   - Set TEST_MODE=false.
   - Save the script and launch it as a background service or systemd user service.

