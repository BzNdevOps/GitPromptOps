# Prompt Lab

Repository de prompts versionnés géré par **promptlab.ps1**.

## Structure

```
prompts/
├── strategy/     # Prompts stratégiques
├── coding/       # Prompts de code
├── ops/          # Prompts opérationnels
└── trading/      # Prompts trading
```

## Usage

```powershell
# Mode interactif
.\promptlab.ps1

# Créer un prompt
.\promptlab.ps1 new -Domain trading -Name ma_strategie -Version 1.0.0

# Doctor (vérification)
.\promptlab.ps1 doctor
```

## Index

Voir [prompts/_index.md](prompts/_index.md) pour la liste complète.

---
Généré par promptlab.ps1 v2.1
