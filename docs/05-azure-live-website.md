# Put the website live on Azure (free with Azure for Students)

Same goal as the AWS guide, using **Azure for Students**: $100 of credit, no credit card,
renewable each year you're a full-time student. When the credit runs out, Azure switches
your resources off instead of charging you.

```
 Anyone's browser ──► http://sre-quotes-xxxxx.<region>.cloudapp.azure.com ──► Linux VM (Docker Compose)
                                                   ├─ api   ── syslog ──► Azure Monitor Agent ──► Log Analytics ──► alert ──► your email
                                                   ├─ redis ── syslog ──►            "
                                                   ├─ prometheus  (only your IP)
                                                   └─ grafana     (only your IP)
```

Everything is created by **Terraform** (`terraform/azure/`): one command builds it, one deletes it.

| AWS word | Azure word |
|---|---|
| EC2 instance | Virtual machine (VM) |
| Security group | Network security group (NSG) |
| CloudWatch Logs + Logs Insights | Log Analytics workspace + KQL queries |
| CloudWatch alarm + SNS | Azure Monitor alert + action group |
| Systems Manager run command | VM Run Command |

---

## Step 1 — Try the website on your laptop first

```bash
make compose-down
make compose-up
```

Open **http://localhost:8080**. Click **Simulate a server error (500)**, copy the
`request_id` the page shows, and find it:

```bash
docker compose logs api | grep PASTE-THE-START-OF-THE-ID
```

You'll find the `ERROR` line (why it failed) and the request line (`"status": 500`).
That's the skill you'll repeat in Azure below.

## Step 2 — Activate Azure for Students

1. Go to https://azure.microsoft.com/free/students and click **Start free**.
2. Sign in with your **school email** and verify. No card needed.
3. In the portal (https://portal.azure.com), search **Education** → you'll see your credit balance.
   Check it here any time.

## Step 3 — Install the tools on your Mac

```bash
brew install azure-cli
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
```

You also need an SSH key (your key to log in to the server). Check if you have one:

```bash
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519      # press Enter for all questions
```

Sign in to Azure and get your subscription ID:

```bash
az login                                  # a browser opens — sign in with your school account
az account show --query id -o tsv         # copy this ID
```

## Step 4 — Put the project on GitHub

The server downloads your code from GitHub, so it must be there and **public**.
Create an empty repo called `sre-quotes-project` on github.com, then from the project folder:

```bash
git init
git add .
git commit -m "Quotes site with Azure setup"
git branch -M main
git remote add origin https://github.com/YOUR_GITHUB_USER/sre-quotes-project.git
git push -u origin main
```

## Step 5 — Fill in your settings

```bash
cd terraform/azure
cp terraform.tfvars.example terraform.tfvars
curl -s https://checkip.amazonaws.com       # your public IP
open -e terraform.tfvars
```

Fill in `subscription_id`, `repo_url`, `my_ip_cidr` (your IP + `/32`) and `alert_email`. Save.

## Step 6 — Build it

```bash
terraform init      # downloads the Azure plugin (once)
terraform plan      # SHOWS what will be created — read it; nothing changes yet
terraform apply     # type 'yes' (~3–5 minutes)
```

Always `plan` before `apply`: look before you change production.

When it finishes it prints your URLs. See them again any time:

```bash
terraform output
terraform output -raw grafana_password
```

Azure sends a "You've been added to an action group" email — that's your alert email working.

## Step 7 — Open your live website

The server needs **5–10 minutes** after `apply` to install Docker and build the app.
Then open `website_url`. It's on the internet — send it to a friend.

Open `grafana_url` too (user `admin`, password from above). It only opens from your IP:
try your phone on mobile data and it won't load. That's the NSG firewall working.

## Step 8 — Search the logs in Log Analytics

Open `logs_link` from `terraform output` (or portal → *Log Analytics workspaces* →
`sre-quotes-logs-…` → *Logs*). Close the "Queries" pop-up, switch the editor to **KQL mode**,
paste a query and click **Run**.

> The first logs can take **10–15 minutes** to appear while the monitoring agent installs.
> Visit your site a few times to create some.

Every request, as a table (save this one — it's the base for the others):
```kusto
Syslog
| where Facility == "local0"
| extend log = parse_json(extract(@"(\{.*\})", 1, SyslogMessage))
| where isnotempty(log.msg)
| project TimeGenerated, container = ProcessName, level = tostring(log.level),
          msg = tostring(log.msg), status = toint(log.status), path = tostring(log.path),
          request_id = tostring(log.request_id), duration_ms = todouble(log.duration_ms),
          error = tostring(log.error)
| order by TimeGenerated desc
```

Only errors — add these lines before `| order by`:
```kusto
| where status >= 500 or level == "ERROR"
```

One user's request — add:
```kusto
| where request_id == "PASTE-ID-HERE"
```

Slowest requests — replace the last line with:
```kusto
| where isnotnull(duration_ms) | top 20 by duration_ms desc
```

Traffic per minute by status code (click **Chart** above the results):
```kusto
Syslog
| where Facility == "local0"
| extend status = toint(parse_json(extract(@"(\{.*\})", 1, SyslogMessage)).status)
| where isnotnull(status)
| summarize requests = count() by bin(TimeGenerated, 1m), tostring(status)
```

## Step 9 — Make the alert email you

On your live site, click **Simulate a server error (500)** 5 or more times.
Within about **10 minutes** you'll get an alert email for `sre-quotes-high-5xx`
(log alerts are slower than metric alerts: logs must arrive, then the rule runs every 5 min).
When errors stop, a "resolved" email follows.

See it in the portal: **Monitor → Alerts**. The rule itself is in `terraform/azure/main.tf`.

## Step 10 — A real incident in the cloud

Log in to the server and break it:

```bash
cd terraform/azure
$(terraform output -raw ssh_command)       # type 'yes' the first time
sudo -i
cd /opt/sre-quotes
docker compose -f docker-compose.yml -f docker-compose.azure.yml stop redis
exit; exit
```

Now pretend you don't know what happened. Use the website (the status line at the bottom),
your Log Analytics queries, and your email to work out what broke. Then fix it on the server:

```bash
docker compose -f docker-compose.yml -f docker-compose.azure.yml start redis
```

Write it up with `docs/03-postmortem-template.md`. Your quotes survive: Redis saves to disk.

Other things to look at while logged in:
```bash
docker compose -f docker-compose.yml -f docker-compose.azure.yml ps     # what's running
docker compose -f docker-compose.yml -f docker-compose.azure.yml logs -f api
free -h                                                                 # memory
df -h                                                                   # disk
```

## Step 11 — Ship a change, then clean up

**Deploy a change:** edit the subtitle in `app/static/index.html`, then:
```bash
git commit -am "Change subtitle" && git push
./scripts/azure-deploy.sh
```
Check `website_url/healthz`: `version` is now your latest commit ID.

**When you're done practising, delete everything** (saves your credit):
```bash
cd terraform/azure
terraform destroy      # type 'yes'
```
Re-create it any time with `terraform apply`. Check your remaining credit in the portal
(search **Education**).

---

## Troubleshooting

| Problem | What to check |
|---|---|
| `apply` fails with **RequestDisallowedByAzure** / policy error | Azure for Students only allows certain regions. The error lists them — set `location = "<one of them>"` in `terraform.tfvars` and apply again. |
| `apply` fails with **SkuNotAvailable** | That VM size isn't available in that region. Try `vm_size = "Standard_B1ms"` or another region. |
| Website doesn't load after 10 min | SSH in and run `sudo cat /var/log/user-data.log`. Usual causes: repo URL wrong or repo private. |
| Can't SSH / Grafana won't load | Your IP changed. Update `my_ip_cidr`, run `terraform apply`. |
| No logs in Log Analytics after 15 min | SSH in: `systemctl status azuremonitoragent` should be *active*; `sudo systemctl restart rsyslog azuremonitoragent`. In the portal check Monitor → Data Collection Rules → `sre-quotes-app-logs` → Resources lists your VM. |
| No alert email | Check spam; confirm 5+ errors happened within 5 minutes; check Monitor → Alerts. |
| Site is slow / out of memory | `vm_size = "Standard_B1ms"` (2 GB RAM) in `terraform.tfvars`, then `terraform apply`. |

## What you practised (for your résumé)

- **Infrastructure as Code** with Terraform on Azure (VM, VNet, NSG, managed identity, Log Analytics, Azure Monitor)
- **Centralised logging** with the Azure Monitor Agent and **KQL** queries
- **Log-based alerting** with action groups, plus VM availability alerts
- **Least-exposure networking**: public website, admin tools locked to one IP, key-only SSH
- **Deploying** and **incident response** on a live cloud system
