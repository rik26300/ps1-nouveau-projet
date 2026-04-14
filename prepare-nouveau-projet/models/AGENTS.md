# AGENTS.md

## Objectif
Ce projet est maintenu avec l'aide de Codex.
L'agent doit privilégier les modifications cohérentes, lisibles, réutilisables et compatibles avec l'existant.

## Règles générales
- Toujours privilégier la réutilisation du code existant.
- Si plusieurs actions sont très similaires, créer une fonction commune, un composant commun ou une structure commune.
- Ne pas dupliquer inutilement la logique métier.
- Préférer les solutions simples, lisibles et maintenables.
- En cas de doute, conserver le comportement existant plutôt que réinventer la structure du projet.

## Encodage
- Toujours utiliser UTF-8 adapté au français.
- Vérifier systématiquement qu'aucun mojibake n'a été introduit.
- Ne jamais corriger un problème d'accents en repassant un fichier en ASCII.
- Les fichiers texte, scripts, notices et configurations doivent rester lisibles avec les accents français.

## Modifications de fichiers
- Avant de modifier un fichier existant, comprendre sa logique actuelle.
- Respecter le style déjà en place dans le projet.
- Ne pas faire de refonte large si une correction ciblée suffit.
- Lorsqu'un nouveau comportement ressemble à un comportement existant, s'appuyer dessus au lieu de recréer une autre variante.
- Toute création de fichier doit être cohérente avec la structure actuelle du projet.

## Git et dépôt
- Ne jamais faire de commande destructive sans demande explicite.
- Ne pas supprimer ou réinitialiser des modifications utilisateur sans autorisation claire.
- Si des fichiers sont ignorés par Git, ne pas bloquer toute la chaîne de commit pour autant.

## Tests et données
- Si des données de test sont créées, elles doivent être supprimées après test.
- Aucun test persistant ne doit laisser de données de test derrière lui.
- Si une base de données est utilisée, nettoyer les données créées pendant les vérifications.
- Ne pas toucher aux données réelles sans nécessité explicite.

## Documentation
- Si une notice ou un README est généré, il doit être clair, en français, et cohérent avec le comportement réel du projet.
- Ne pas documenter un comportement qui n'existe pas réellement.
