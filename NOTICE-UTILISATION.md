# Notice d'utilisation

## Installation

Copier et coller les fichiers "prepare-nouveau-projet.ps1" et "prepare-nouveau-projet.cmd" dans votre dossier projet.

## Lancer le script en manuel

Depuis PowerShell :

```
cd <chemin_de_votre_dossier_projet>
.\prepare-nouveau-projet.ps1
```

## Activer l'ouverture par double clic

Solution recommandée :

Utiliser "prepare-nouveau-projet.cmd" par double clic.

Ce lanceur évite le bug de Windows/PowerShell quand le chemin du dossier contient des espaces, par exemple "D:\aymeric\projects\ps1 nouveau projet".

Solution alternative :

Si vous souhaitez ouvrir directement les fichiers ".ps1" par double clic, vous pouvez modifier la commande d'ouverture de PowerShell.

Commencez par associer les fichiers ".ps1" à PowerShell natif de Windows :

1. Faites un clic droit sur un fichier ".ps1".
2. Choisissez "Ouvrir avec".
3. Cliquez sur "Choisir une autre application".
4. Sélectionnez "Plus d'applications" puis "Rechercher une autre application sur ce PC" si nécessaire.
5. Associez le type de fichier à "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe".
6. Cochez l'option pour toujours utiliser cette application.

Ensuite, si le double clic échoue encore quand le chemin contient des espaces, vous pouvez modifier la commande d'ouverture dans le registre :

Clé d'origine :

```
HKEY_CLASSES_ROOT\Applications\powershell.exe\shell\open\command
"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" "%1"
```

Clé modifiée :

```
HKEY_CLASSES_ROOT\Applications\powershell.exe\shell\open\command
"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" "& \"%1\""
```

Avec ce changement, le chemin du script est bien transmis même s'il contient des espaces.

## Erreur d'exécution des scripts PowerShell

Si PowerShell affiche une erreur indiquant que l'exécution de scripts est désactivée sur le système, il faut autoriser l'exécution des scripts pour votre compte utilisateur avec la commande suivante :

```
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Ensuite, confirmez avec "O" si PowerShell demande une validation, puis relancez le script.

L'utilisation de "prepare-nouveau-projet.cmd" ou la modification de la clé registre ne remplace pas cette autorisation PowerShell.
