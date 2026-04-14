# ps1 nouveau projet

Script PowerShell pour préparer rapidement un nouveau projet de développement avec une structure cohérente, des fichiers de base et des automatismes de configuration.

## Objectif

`prepare-nouveau-projet.ps1` sert à :

- créer un nouveau dossier de projet
- générer les fichiers de base selon le type de projet
- préparer les projets Python et Django
- gérer les fichiers communs comme `README.md`, `.gitignore` et `AGENTS.md`
- proposer la mise à jour d'un projet existant
- centraliser les modèles et ressources de référence dans une bibliothèque personnalisable

## Types de projets gérés

Le script connaît actuellement les types suivants :

- `cmd`
- `bat`
- `ps1`
- `py`
- `django`
- `autre`

Les projets `django` héritent des règles et fichiers Python, avec leur couche spécifique en plus.

## Architecture du dépôt

Le dépôt est organisé autour de deux éléments principaux :

- `prepare-nouveau-projet.ps1` : script principal
- `prepare-nouveau-projet/` : dossier de référence

Le dossier de référence contient notamment :

- `prepare-nouveau-projet/NOTICE-UTILISATION.md`
- `prepare-nouveau-projet/models/`
- `prepare-nouveau-projet/depots python/`

## Système de modèles

Le script ne génère plus ses fichiers principaux en dur autant que possible. Il s'appuie sur une bibliothèque de modèles dans `prepare-nouveau-projet/models`.

Principe :

- les fichiers communs sont placés directement dans `models`
- les sous-dossiers par type permettent d'ajouter ou remplacer du contenu
- `ajout_<nomDuFichier>` ajoute du contenu au modèle de base
- `remplace_<nomDuFichier>` remplace complètement le modèle de base pour un type donné

Exemple :

- `models/AGENTS.md`
- `models/python/ajout_AGENTS.md`

Dans ce cas, le contenu Python est ajouté au fichier `AGENTS.md` commun uniquement pour les projets Python.

## Lancement rapide

Depuis PowerShell :

```powershell
.\prepare-nouveau-projet.ps1
```

Ou via le lanceur :

```powershell
.\prepare-nouveau-projet.cmd
```

La notice détaillée est disponible dans `prepare-nouveau-projet/NOTICE-UTILISATION.md`.

## Fonctionnalités principales

- création de projet neuf
- mise à jour d'un projet existant
- import d'un dépôt GitHub existant
- gestion d'un dépôt Git local et configuration GitHub
- prise en charge des environnements virtuels Python
- création d'un projet Django après installation de l'environnement
- vérification de version du script au démarrage
- mise à jour du script depuis le GitHub public
- récupération guidée des modèles manquants

## Configuration

La configuration du script est stockée dans :

- `prepare-nouveau-projet/prepare-nouveau-projet.config.json`

Si une ancienne configuration existe encore à la racine, le script la déplace automatiquement vers ce nouvel emplacement.

## Philosophie du projet

Le projet cherche à garder une logique simple :

- un flux de création et de mise à jour aussi proches que possible
- une bibliothèque de modèles modifiable par l'utilisateur
- des valeurs par défaut pensées pour un usage personnel en français
- une structure de fichiers visible et compréhensible
