# Upload GitHub (sans Git local)

## Method 1: GitHub Web UI

1) Ouvre ton repo GitHub: https://example.com/repo.git
2) Clique **Add file** → **Upload files**
3) Dézippe puis glisse-dépose le contenu du ZIP (garder l'arborescence):
   - prompts/
   - README.md (si présent)
4) Message de commit: `promptlab: update prompts`
5) Branch: `main` (ou ta branch active)
6) Clique **Commit changes**

## Method 2: GitHub CLI (si installé)

```bash
gh repo sync
unzip promptlab_upload_*.zip -d .
git add prompts README.md
git commit -m "promptlab: update prompts"
git push origin main
```

## Verify Upload

After upload, check:
- [OK] prompts/_index.md is updated
- [OK] Version numbers are correct
- [OK] README links work

---
Generated: 2026-01-05 00:22:59