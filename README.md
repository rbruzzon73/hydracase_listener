# HydraCaseBot Slack Email Relay

Automated Bash tooling to intercept, sanitize, and forward Red Hat **HydraCaseBot** case update notifications from Slack to internal email via local SMTP relay.

---

## Features

## Features

- **Automated SSO & Self-Healing Session Management**:
  - Automatically extracts active Slack Web API session tokens (`xoxc-`) and session cookies (`d=...`) directly from Firefox LocalStorage (`data.sqlite`).
  - Pre-flight `auth.test` verification ensures API credentials remain valid before every polling cycle.
  - Automatically recovers missing or expired sessions via SAML SSO Kerberos negotiation (`user.js` SPNEGO enforcement).
  - Dynamically triggers a GUI bootstrap when databases are missing, monitors `data.sqlite` creation in real-time, and seamlessly transitions back to background headless execution.

- **Dynamic User & Profile Resolution**:
  - Out-of-the-box support for any Linux user account (`$USER`) by dynamically discovering active Firefox profiles (including `default-redhat`, `RedHat.default`, `*.default-release`, and `*.default`).
  - Directly binds to the profile directory using `--profile` and `--no-remote`, avoiding manual profile-picker prompts and conflicts with active browser instances.

- **Robust Cleanup & Process Sanitization**:
  - Automatically removes lingering Firefox lock files (`.parentlock`, `parent.lock`, `lock`) and terminates zombie instances before session refreshes and upon exit.
  - Suppresses SQLite WAL checkpoint output (`0|-1|-1`) to keep background execution logs clean.

- **Clean Parsing & Labeled Content Processing**:
  - Automatically unescapes HTML entities, strips Slack markdown syntax, resolves user mentions (`<@U...>`), and extracts structured metadata (Case Number, Title, Severity, Status, Owner, Platform, SBT, and direct Salesforce/Portal URLs).

- **Multi-Card Message Splitting**:
  - Unpacks Slack messages containing multiple attachment blocks and forwards each alert as a distinct, individually formatted email notification.

- **Embedded Test Harness**:
  - Includes a built-in mock event generator (`send_mock_event.sh`) with an interactive CLI menu to perform end-to-end delivery testing without relying on live production alerts.

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
The core background daemon that polls Slack for new `HydraCaseBot` alerts, manages automated Kerberos SAML SSO session renewals, extracts structured metadata, and dispatches formatted notification emails.

* **Key Variables & Configuration**:
  * `TARGET_CHANNEL_ID`: The target channel or Direct Message ID with `HydraCaseBot` (e.g., `D04NRQ0PNJV`).
  * `BOT_USER_ID`: The official `HydraCaseBot` Member ID (e.g., `U04JNCVBVNU`).
  * `SLACK_SAML_URL`: Direct SAML SSO bootstrap endpoint used for automatic GUI re-authentication (`https://redhat.enterprise.slack.com/sso/saml/start?...`).
  * `SLACK_HEADLESS_URL`: Direct client URL used for background headless polling and session keep-alive (`https://app.slack.com/client/...`).
  * `TEST_MODE`: When set to `true`, listens for mock messages sent by your personal user account (`TEST_USER_ID`) in addition to official bot alerts and appends `[TEST]` to email subject lines.
  * `SMTP_SERVER`: Internal corporate mail relay endpoint (`smtp.corp.redhat.com:25`).

* **Core Responsibilities**:
  * **Session Resilience**: Continuously verifies `xoxc-` tokens and `d` cookies via `auth.test`. Automatically triggers an automated SAML SSO GUI bootstrap if databases are missing, or a background headless refresh if credentials expire.
  * **Dynamic Firefox Binding**: Automatically resolves active Red Hat Enterprise profiles (prioritizing `default-redhat`) and binds directly to the filesystem path (`--profile`) without triggering profile-selection dialogs.
  * **Process & Lock Sanitization**: Cleans up lingering `.parentlock` and `parent.lock` files, prevents database locks during SQLite reads, and terminates orphan Firefox instances on exit.
  * **Metadata Parsing & Delivery**: Extracts structured fields (Case Number, Title, Severity, Status, Account, Owner, Platform, SBT) from complex Slack attachment blocks and sends individual, formatted HTML-decoded emails via `mailx`.

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
# 1. System Packages (Fedora/RHEL/DNF)
sudo dnf install -y firefox jq curl sqlite coreutils s-nail binutils python3-pip

# 2. Python Packages
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
- Edit hydracase_listener.sh and enable the debug mode (`TEST_MODE=true`)
- Start hydracase_listener.sh in debug mode: `./hydracase_listener.sh`
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

