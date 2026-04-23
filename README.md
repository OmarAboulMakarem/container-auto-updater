# Container-Auto-Updater

A lightweight container that watches private Docker registries (AWS ECR, Oracle OCIR, Docker Hub) for image updates and automatically redeploys your `docker compose` stack when a new digest is detected.

Similar to [Watchtower](https://containrrr.dev/watchtower/) or [WUD](https://getwud.github.io/wud/), but intentionally minimal: a single Bash script loop with no daemon, no state file, no web UI, and a self-healing retry flow.

---

## Quick start

### Pull the image

```bash
docker pull ghcr.io/omaraboulmakarem/container-auto-updater:latest
```

### Run standalone (minimal)

```bash
docker run -d \
  --name container-auto-updater \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /path/to/your/docker-compose.yml:/compose/docker-compose.yml:ro \
  -e WATCH_IMAGES="ghcr.io/youruser/yourapp:latest" \
  -e COMPOSE_FILE="/compose/docker-compose.yml" \
  -e CA_UPDATER_PROJECT_NAME="my-app" \
  -e NOTIFY_PROVIDER="smtp" \
  -e EMAIL_FROM="alerts@yourdomain.com" \
  -e EMAIL_TO="ops@yourdomain.com" \
  -e SMTP_HOST="smtp.yourdomain.com" \
  -e SMTP_PORT="587" \
  -e SMTP_USERNAME="alerts@yourdomain.com" \
  -e SMTP_PASSWORD="yourpassword" \
  ghcr.io/omaraboulmakarem/container-auto-updater:latest
```

### Run with an env file

```bash
cp .env.example .env
# edit .env with your values

docker run -d \
  --name container-auto-updater \
  --restart unless-stopped \
  --env-file .env \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /path/to/your/docker-compose.yml:/compose/docker-compose.yml:ro \
  ghcr.io/omaraboulmakarem/container-auto-updater:latest
```

### Run with Docker Compose

Add the watcher as a service in your existing `docker-compose.yml`:

```yaml
services:
  your-app:
    image: ghcr.io/youruser/yourapp:latest
    restart: unless-stopped

  container-auto-updater:
    image: ghcr.io/omaraboulmakarem/container-auto-updater:latest
    restart: unless-stopped
    read_only: true
    cap_drop:
      - ALL
    env_file: .env                          # or use environment: block below
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /path/to/your/docker-compose.yml:/compose/docker-compose.yml:ro
```

Then start it:

```bash
docker compose up -d container-auto-updater
docker compose logs -f container-auto-updater
```

See `docker-compose.example.yml` in this repo for a fully annotated example with all environment variables.

---

## How it works

1. Every `CHECK_INTERVAL_MINUTES` minutes, the watcher authenticates against the registry for each image in `WATCH_IMAGES`.
2. It fetches the remote manifest digest (retrying up to 3 times on transient errors) and compares it against the locally deployed image digest.
3. If the digests differ, it runs `docker compose pull && docker compose up -d`.
4. It waits 60 seconds, then verifies all services are running/healthy.
5. It sends an email (via SendGrid or SMTP) with the outcome, a container status table, and — on failure — logs from the affected services.

**Self-healing on failure:**

```
Initial redeploy fails
  → email: REDEPLOY FAILED (status table + per-service logs)
  → wait 2 minutes → re-check health
    ├─ recovered on own → email: recovered automatically
    └─ still unhealthy → docker compose up -d --force-recreate
         → wait 1 minute → re-check health
           ├─ healthy → email: recovered via force-recreate
           └─ still failing → email: STILL FAILING — manual intervention required
```

No redeploy happens if the image is unchanged. One redeploy per cycle maximum.

---

## Supported registries

| Registry | Auth mechanism |
|---|---|
| AWS ECR | `aws ecr get-login-password` — IAM credentials |
| Oracle OCIR | OCI Auth Token — tenancy username + auth token |
| Docker Hub | Personal Access Token |
| GHCR / any OCI-compliant registry | Not yet supported with auto-login (PRs welcome) |

The registry is detected automatically from the image hostname — no config needed beyond the credentials for your registry.

---

## Environment variables

### Required

| Variable | Description |
|---|---|
| `WATCH_IMAGES` | Comma-separated list of full image refs to watch, e.g. `ghcr.io/youruser/app:latest,nginx:stable` |
| `COMPOSE_FILE` | Path to your `docker-compose.yml` **inside the watcher container** — must match your volume mount, e.g. `/compose/docker-compose.yml` |
| `EMAIL_FROM` | Sender address |
| `EMAIL_TO` | Comma-separated list of recipient addresses |

### Optional

| Variable | Default | Description |
|---|---|---|
| `CA_UPDATER_PROJECT_NAME` | Parent dir of `COMPOSE_FILE` | Project name shown in email subjects. Set this explicitly — the default resolves to `compose` when using the recommended mount path. |
| `COMPOSE_ENV_FILE` | — | Path to a `.env` file **inside the watcher container** passed to all `docker compose` commands via `--env-file`. Required if your compose file uses `required` variable syntax (e.g. `${VAR:?}`). Mount your app's `.env` and set this to the mount path. |
| `CA_UPDATER_SERVICE_NAME` | `container-auto-updater` | Name of the watcher service in your compose file. This service is excluded from `pull` and `up` at redeploy time to prevent a self-conflict (the running watcher can't be replaced by itself mid-run). |
| `CA_UPDATER_COMPOSE_PROJECT_NAME` | auto-detected | Docker Compose project name of your stack. The watcher auto-detects this from the `com.docker.compose.project` label on running containers. Only set this if auto-detection fails or you want to be explicit. |
| `CHECK_INTERVAL_MINUTES` | `5` | How often to poll registries, in minutes |
| `SKIP_FIRST_RUN` | `false` | Set to `true` to skip the redeploy check on first startup, preventing a spurious redeploy every time the watcher container restarts |

### Notifications

| Variable | Default | Description |
|---|---|---|
| `NOTIFY_PROVIDER` | `sendgrid` | `sendgrid` or `smtp` |

**SendGrid** (`NOTIFY_PROVIDER=sendgrid`):

| Variable | Description |
|---|---|
| `SENDGRID_API_KEY` | SendGrid API key with Mail Send permission |

**SMTP** (`NOTIFY_PROVIDER=smtp`):

| Variable | Default | Description |
|---|---|---|
| `SMTP_HOST` | — | SMTP server hostname |
| `SMTP_PORT` | `587` | `587` = STARTTLS, `465` = implicit TLS (smtps), `25` = plain |
| `SMTP_USERNAME` | — | Leave blank for unauthenticated relay |
| `SMTP_PASSWORD` | — | SMTP password |

### AWS ECR (only needed for ECR images)

| Variable | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM access key with `ecr:GetAuthorizationToken` + `ecr:BatchGetImage` |
| `AWS_SECRET_ACCESS_KEY` | IAM secret access key |
| `AWS_REGION` | AWS region, e.g. `us-east-1` |

### Oracle OCIR (only needed for OCIR images)

| Variable | Description |
|---|---|
| `OCIR_USERNAME` | `<tenancy-namespace>/<username>` or `<tenancy-namespace>/oracleidentitycloudservice/<email>` |
| `OCIR_AUTH_TOKEN` | OCI Auth Token (generated under your OCI user profile — not your account password) |

### Docker Hub (only needed for private Docker Hub images)

| Variable | Description |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub Personal Access Token |

---

## Volume mounts

| Mount | Purpose |
|---|---|
| `/var/run/docker.sock:/var/run/docker.sock` | Required — gives the watcher access to the host Docker daemon |
| `/path/to/your/docker-compose.yml:/compose/docker-compose.yml:ro` | Required — the compose file to redeploy. Set `COMPOSE_FILE=/compose/docker-compose.yml` to match. |

---

## Email notifications

| Event | Subject | Body contains |
|---|---|---|
| Redeploy succeeded | `[ca-updater] <project> — redeployed successfully` | Image ref, old/new digest, timestamp, container status table |
| Redeploy failed | `[ca-updater] <project> — REDEPLOY FAILED` | Status table, redeploy output, last 20 lines of logs per failing service, recovery notice |
| Recovered automatically | `[ca-updater] <project> — recovered automatically` | Status table |
| Recovered via force-recreate | `[ca-updater] <project> — recovered via force-recreate` | Force-recreate output, status table |
| Still failing after all attempts | `[ca-updater] <project> — STILL FAILING after force-recreate` | Status table, last 20 lines of logs per failing service |

A notification failure is logged but never crashes the watcher.

---

## Logs

Logs are structured JSON, readable by Datadog, CloudWatch, Loki, and similar tools:

```json
{"level":"info","time":"2026-04-23T10:00:00Z","msg":"Starting auto-pull watcher","images":"ghcr.io/youruser/app:latest","interval":"5m"}
{"level":"info","time":"2026-04-23T10:00:01Z","msg":"Checking image","image":"ghcr.io/youruser/app:latest"}
{"level":"info","time":"2026-04-23T10:00:02Z","msg":"Up to date","image":"ghcr.io/youruser/app:latest","digest":"sha256:abc123..."}
{"level":"info","time":"2026-04-23T10:05:01Z","msg":"Update detected","image":"ghcr.io/youruser/app:latest","old":"sha256:abc...","new":"sha256:def..."}
{"level":"info","time":"2026-04-23T10:06:05Z","msg":"Redeploy succeeded","image":"ghcr.io/youruser/app:latest"}
```

---

## Building from source

```bash
git clone https://github.com/omaraboulmakarem/container-auto-updater.git
cd container-auto-updater
docker build -t container-auto-updater:local .
```

---

## CI/CD

The `.gitlab-ci.yml` builds and pushes on every push to `main`, `master`, `develop`, or a merge request. Two registries are updated each run:

| Registry | Tags pushed |
|---|---|
| `ghcr.io/omaraboulmakarem/container-auto-updater` | `latest`, `1.0.<pipeline_iid>` |

**Required GitLab CI/CD variables** (masked, expand variables OFF):

| Variable | Description |
|---|---|
| `OCI_USERNAME` | Oracle OCIR username |
| `OCI_AUTH_TOKEN` | Oracle OCIR auth token |
| `GHCR_USERNAME` | GitHub username (`omaraboulmakarem`) |
| `GHCR_TOKEN` | GitHub PAT with `write:packages` scope |

---

## Security notes

- The watcher requires `/var/run/docker.sock`, which grants root-equivalent access to the host. Run it on trusted infrastructure only.
- The compose example includes `read_only: true` and `cap_drop: [ALL]` — keep these in your deployment.
- Registry credentials are passed as environment variables. Use Docker secrets or a secrets manager in sensitive environments.

---

## Contributing

PRs welcome. Planned improvements include webhook notifications (Slack/Discord/Teams), GHCR auth support, per-image poll intervals, dry-run mode, pre/post-deploy hooks, and a deploy window scheduler.
