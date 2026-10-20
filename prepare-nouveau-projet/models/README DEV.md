# Développement de {{PROJECT_NAME}}

Ce dossier contient les ressources locales de développement. Le dépôt Git est
uniquement le sous-dossier `{{PROJECT_NAME}}/` : exécuter les commandes Git dedans.
Les outils personnels, `.venv`, `AGENTS.md` et la feuille de route restent hors Git.

## Python

Si un environnement Python a été créé, lancer `cmdVenv.cmd` ou activer
`.venv/Scripts/Activate.ps1` depuis ce dossier. Le code, les dépendances et
`pyproject.toml` restent dans le sous-dossier du projet.

## Django

Pour un projet autonome, `manage.py` se trouve dans le sous-dossier du projet.
Pour une application réutilisable, le site Django de test et son `manage.py`
se trouvent ici. L'application est enregistrée dans ce site de développement.

Les fichiers de ce dossier sont locaux et doivent être sauvegardés séparément
si nécessaire. Seul le contenu du sous-dossier du projet est publié sur Git.
