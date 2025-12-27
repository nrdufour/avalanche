# wger Workout Manager

Workout, nutrition, and weight tracking application.

## Deployment

- **URL**: https://wger.home.internal
- **Namespace**: self-hosted
- **Database**: PostgreSQL 16 (CNPG, 3 replicas)
- **Cache**: Redis 7.4

## Required Secrets

The application requires two secrets stored in Vaultwarden (Bitwarden "Self Hosted" item, UUID: `6abe895f-83ea-4e1d-9610-a9324093d608`):

### WGER_SECRET_KEY
Django secret key used for cryptographic signing (sessions, cookies, CSRF tokens).

**Requirements**:
- 50+ random characters
- Should never be rotated in production (breaks sessions)

**Generate**:
```bash
# Using Django utility
python3 -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'

# Or using openssl
openssl rand -base64 50
```

### WGER_SIGNING_KEY
JWT signing key used for API authentication tokens.

**Requirements**:
- Random hex string (64+ characters recommended)
- Can be rotated if needed (invalidates all existing JWT tokens)

**Generate**:
```bash
openssl rand -hex 32
```

## First-Time Setup

After deployment, create an admin user:

```bash
kubectl -n self-hosted exec -it deployment/wger -- python manage.py createsuperuser
```

Follow the prompts to set username, email, and password.

## Database

- **Bootstrap**: `initdb` (new database, no recovery)
- **Backups**: Daily at midnight (scheduled-backup.yaml)
- **Retention**: 30 days (objectstore-backup.yaml)
- **Storage**: 5Gi per instance on Orange Pi 5+ nodes

## Features

- Workout planning and tracking
- Exercise database (auto-synced from wger.de)
- Nutrition tracking with meal plans
- Weight and body measurement tracking
- Celery background jobs for data synchronization
- REST API with JWT authentication
- Multi-language support

## Resources

- **Application**: 100m CPU, 512Mi-1Gi memory
- **PostgreSQL**: 100m CPU, 128Mi-512Mi memory (per instance)
- **Redis**: 10m CPU, 64Mi-256Mi memory

## Monitoring

Check deployment status:
```bash
# ArgoCD
argocd app get wger

# Pods
kubectl -n self-hosted get pods -l app=wger
kubectl -n self-hosted get pods -l app=wger-redis
kubectl -n self-hosted get pods -l cnpg.io/cluster=wger-16-db

# Logs
kubectl -n self-hosted logs -f deployment/wger
```

## Troubleshooting

### Database connection issues
Check CNPG cluster status:
```bash
kubectl -n self-hosted get cluster wger-16-db
kubectl -n self-hosted describe cluster wger-16-db
```

### Slow first startup
First startup takes 2-3 minutes for:
- Database migrations
- Initial exercise sync from wger.de
- Static file collection

### Redis connection issues
Verify Redis is running:
```bash
kubectl -n self-hosted get pods -l app=wger-redis
kubectl -n self-hosted logs deployment/wger-redis
```
