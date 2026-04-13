# Notice d'utilisation

## Installation

Copier et coller le fichier "prepare-nouveau-projet.ps1" dans votre dossier projet.

## Lancer le script en manuel

Depuis PowerShell :

```
cd <chemin_de_votre_dossier_projet>
.\prepare-nouveau-projet.ps1
```

## Activer l'ouverture par double clic

Si vous souhaitez qu'un double clic exécute les fichiers ".ps1" avec PowerShell au lieu de les ouvrir en modification :

1. Faites un clic droit sur un fichier ".ps1".
2. Choisissez "Ouvrir avec".
3. Cliquez sur "Choisir une autre application".
4. Sélectionnez "Plus d'applications" puis "Rechercher une autre application sur ce PC" si nécessaire.
5. Associez le type de fichier à "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe".
6. Cochez l'option pour toujours utiliser cette application.

## Erreur d'exécution des scripts PowerShell

Si PowerShell affiche une erreur indiquant que l'exécution de scripts est désactivée sur le système, il faut autoriser l'exécution des scripts pour votre compte utilisateur avec la commande suivante :

```
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Ensuite, confirmez avec "O" si PowerShell demande une validation, puis relancez le script.

L'association pour le double clic ne remplace pas cette autorisation PowerShell.
