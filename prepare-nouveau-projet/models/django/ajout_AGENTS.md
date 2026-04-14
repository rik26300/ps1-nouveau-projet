## Django
- Respecter la structure standard Django quand elle existe déjà.
- Ne pas casser les fichiers générés par Django sans raison valable.
- Lors de modifications automatiques de settings.py, ne changer que les lignes ciblées.
- Préférer des changements localisés et explicites.
- Si un projet Django est détecté, tenir compte de manage.py, settings.py, pyproject.toml et requirements.
- Si une app Django est ajoutée plus tard, penser à la cohérence avec INSTALLED_APPS.
