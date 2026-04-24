# GitHub Deployments API — Demo

Minimal demo untuk explore GitHub Deployments API.

## Setup

Pindahkan folder ini dulu keluar dari voila-pos-web:

```bash
mv /Users/adhan/ctlyst/voila-pos-web/github-deployments-demo /Users/adhan/ctlyst/
cd /Users/adhan/ctlyst/github-deployments-demo
```

### Kalau pake `gh` CLI:

```bash
git init -b main
git add .
git commit -m "init: deployments demo"
gh repo create github-deployments-demo --public --source=. --remote=origin --push
gh repo view --web
```

### Manual via web UI:

1. Buka github.com → New repository → `github-deployments-demo` (public) → Create (skip README)
2. ```bash
   git init -b main
   git add .
   git commit -m "init"
   git remote add origin git@github.com:<user>/github-deployments-demo.git
   git push -u origin main
   ```

## Jalankan

1. Buka repo di github.com
2. Tab **Actions** → klik **"Deploy Demo"** di sidebar kiri
3. Klik **"Run workflow"** (kanan atas)
4. Pilih environment: `development` / `staging` / `production`
5. (opsional) Isi `ref` — default `main`
6. Klik **"Run workflow"** (hijau)
7. Tunggu ~10-15 detik

## Lihat Hasil

**Sidebar kanan repo homepage:**
Section **"Deployments"** muncul otomatis (antara Releases & Packages). Nampilin environment aktif + badge status.

**Halaman dedicated:**
```
https://github.com/<user>/github-deployments-demo/deployments
```

- Panel atas: active deployments per environment
- Timeline history per environment
- Klik deployment → detail (commit, log, env URL)

**Per-commit:**
Buka Commits → klik commit yang di-deploy → badge "Deployed to `<env>`" di atas.

**Via CLI:**
```bash
gh api repos/<user>/github-deployments-demo/deployments
gh api "repos/<user>/github-deployments-demo/deployments?environment=staging"
```

## Eksperimen menarik

1. Deploy semua 3 environment (dev, stg, prod) — lihat UI split per-env
2. Deploy `development` 5x → lihat history accumulate
3. Buat tag dummy: `git tag v0.1.0 && git push --tags`, deploy dengan `ref=v0.1.0`
4. Tambah `exit 1` di step "Simulate build" → jalanin → lihat status failure

## Cleanup

```bash
# Archive
gh repo archive <user>/github-deployments-demo --yes

# Atau delete
gh repo delete <user>/github-deployments-demo --yes
```


