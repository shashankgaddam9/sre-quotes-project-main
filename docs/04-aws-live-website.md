# Put the website live on AWS

You'll take the Quotes website off your laptop and run it on a real server in AWS,
reachable by anyone on the internet. Then you'll investigate errors the way an SRE does
in the cloud: through **CloudWatch Logs**, **alarms that email you**, and a terminal on
the server.

```
 Anyone's browser ──► http://<your-server-ip> ──► EC2 server (Docker Compose)
                                                    ├─ api   ── logs ──► CloudWatch Logs ──► alarm ──► your email
                                                    ├─ redis ── logs ──►        "
                                                    ├─ prometheus  (only your IP)
                                                    └─ grafana     (only your IP)
```

Everything is created by **Terraform** (`terraform/aws/`), so one command builds it and
one command deletes it.

> **Cost.** New AWS accounts get free credits, and the setup includes a budget alarm that
> emails you if real spending starts. Still: **run `terraform destroy` when you finish
> practising** (Step 11). A forgotten server keeps billing.

---

## Step 1 — Try the website on your laptop first

The app now has a real web page. Rebuild and open it:

```bash
make compose-down
make compose-up
```

Open **http://localhost:8080**. Add a quote, delete one, click **Another quote**.

Now the SRE part: click **Simulate a server error (500)**. The page shows a message like
`HTTP 500. Search the logs for request_id 3f2a…`. Copy that ID and find it:

```bash
docker compose logs api | grep 3f2a      # paste the start of your ID
```

You'll see two lines with that ID: the `ERROR` explaining *why*, and the request line
with `"status": 500`. **That's the core skill: user reports an error → you find the exact
request in the logs.** You'll do the same thing in AWS below.

---

## Step 2 — Create and secure an AWS account

1. Sign up at https://aws.amazon.com (needs a card; new accounts get credits).
2. **Turn on MFA for the root user**: top-right account menu → Security credentials → Assign MFA.
3. Create a user for daily work (don't use root):
   IAM → Users → Create user → name `admin` → *Attach policies directly* → `AdministratorAccess` → Create.
4. Open that user → Security credentials → **Create access key** → choose *Command Line Interface (CLI)*.
   Keep the two values safe. **Never put them in the project or on GitHub.**

## Step 3 — Install the AWS tools on your Mac

```bash
brew install awscli
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
brew install --cask session-manager-plugin
```

Connect the CLI to your account (paste the access key ID and secret when asked;
region `us-east-1`; output `json`):

```bash
aws configure
aws sts get-caller-identity      # should print your account number and the 'admin' user
```

## Step 4 — Put the project on GitHub

The server downloads your code from GitHub, so it must be there (and the repo must be
**public** for this setup). From the `sre-quotes-project` folder:

```bash
git init
git add .
git commit -m "Quotes site with AWS setup"
git branch -M main
git remote add origin https://github.com/YOUR_GITHUB_USER/sre-quotes-project.git
git push -u origin main
```

(Create the empty repo on github.com first. This is also Step 1 of Phase 4.)

## Step 5 — Fill in your settings

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
curl -s https://checkip.amazonaws.com      # your public IP
open -e terraform.tfvars
```

Set `repo_url` (your GitHub URL), `my_ip_cidr` (your IP followed by `/32`, e.g. `98.12.34.56/32`)
and `alert_email`. Save.

## Step 6 — Build it

```bash
terraform init      # downloads the AWS plugin (once)
terraform plan      # SHOWS what will be created — read it, nothing changes yet
terraform apply     # type 'yes' to create everything (~1 min)
```

`plan` before `apply` is a habit every SRE has: always look before you change production.

When it finishes, it prints your `website_url`, `grafana_url` and more. See them again any time:

```bash
terraform output
terraform output -raw grafana_password
```

**Check your email** and click *Confirm subscription* in the message from AWS Notifications,
otherwise alarms can't reach you.

## Step 7 — Open your live website

The server needs **about 5 minutes** after `apply` to install Docker and build the app.
Then open the `website_url` (e.g. `http://54.12.34.56`). Send the link to a friend — it's live.

Also open `grafana_url` (user `admin`, password from the command above). The same dashboard
as on your laptop, now watching the cloud server. It's only reachable from your IP — try it
on your phone using mobile data and it won't load. That's the firewall (security group) working.

## Step 8 — Read the logs in CloudWatch

Open the `cloudwatch_logs_link` from `terraform output`. You'll see one **log stream** per
container (`…-api-1`, `…-redis-1`). Click the api stream: these are the same JSON lines you
saw with `docker compose logs`, now stored in AWS.

Better: **Logs Insights** lets you *search* logs. CloudWatch → Logs Insights → choose
`/sre-quotes/app` → paste a query → *Run query*.

All errors, newest first:
```
fields @timestamp, status, path, request_id, msg, error
| filter status >= 500 or level = "ERROR"
| sort @timestamp desc
```

One user's request (paste an ID the website showed you):
```
fields @timestamp, @message
| filter request_id = "PASTE-ID-HERE"
```

Slowest requests in the last hour:
```
fields @timestamp, path, duration_ms
| filter ispresent(duration_ms)
| sort duration_ms desc
| limit 20
```

Traffic per minute by status code:
```
filter ispresent(status)
| stats count(*) by bin(1m), status
```

## Step 9 — Make the alarm email you

On your live site, click **Simulate a server error (500)** 5 or more times within a minute.

Within a couple of minutes you'll get an **ALARM** email for `sre-quotes-high-5xx`, then an
**OK** email a few minutes after you stop. In CloudWatch → Alarms you can see it change state.

How it works: a *metric filter* counts log lines where `status >= 500`; the *alarm* fires
when that count reaches 5 in one minute; *SNS* sends the email. All defined in
`terraform/aws/main.tf`.

## Step 10 — A real incident in the cloud

Open a terminal **on the server** (no SSH keys needed — this uses AWS Session Manager):

```bash
cd terraform/aws
$(terraform output -raw open_terminal_on_server)
```

On the server:
```bash
sudo -i
cd /opt/sre-quotes
docker compose -f docker-compose.yml -f docker-compose.aws.yml stop redis
exit; exit
```

Now pretend you don't know what happened. Use the website (the status line at the bottom),
Logs Insights (Step 8), and your email. Work out what broke, then fix it from the server:

```bash
docker compose -f docker-compose.yml -f docker-compose.aws.yml start redis
```

Write it up with `docs/03-postmortem-template.md`. Notice your quotes survived: on AWS,
Redis saves to a disk volume.

## Step 11 — Ship a change, then clean up

**Deploy a change:** edit something visible, such as the subtitle in `app/static/index.html`, then:

```bash
git commit -am "Change subtitle" && git push
./scripts/aws-deploy.sh
```

The script tells the server (via AWS Systems Manager) to pull the new code and rebuild.
Check `website_url/healthz`: `version` now shows your latest commit ID.

**When you're done practising, delete everything:**

```bash
cd terraform/aws
terraform destroy      # type 'yes'
```

Re-create it any time with `terraform apply`. Check AWS → Billing → Bills a day later to
confirm nothing is still running.

---

## Troubleshooting

| Problem | What to check |
|---|---|
| Website doesn't load after 5+ min | Open a terminal on the server (Step 10) and run `sudo cat /var/log/user-data.log` — the setup log. Usual causes: repo URL wrong or repo private. |
| Grafana/Prometheus won't load | Your IP changed (home internet IPs do). Update `my_ip_cidr` in `terraform.tfvars`, run `terraform apply`. |
| No alarm email | Did you click *Confirm subscription*? Check spam. |
| `terraform apply` says no default VPC | Create one: VPC console → Actions → *Create default VPC*. |
| `start-session` fails | Wait 2–3 min after apply; check `session-manager-plugin` is installed. |
| Site is slow / server out of memory | Set `instance_type = "t3.small"` in `terraform.tfvars` and `terraform apply`. |

## What you just practised (for your résumé)

- **Infrastructure as Code** with Terraform (EC2, security groups, IAM least-privilege roles, CloudWatch, SNS, Budgets)
- **Centralised logging** to CloudWatch Logs and querying with Logs Insights
- **Log-based alerting** (metric filter → alarm → email) and **cost guardrails**
- **Keyless server access** with Systems Manager instead of SSH
- **Deploying** changes and **responding to incidents** on a live cloud system
