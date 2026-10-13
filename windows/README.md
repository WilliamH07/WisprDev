# Wisper pour Windows

Dictée vocale maintenue-pour-parler, réécriture IA rapide et réécriture du texte sélectionné, comme la version Mac, pour Windows 10 et 11.

## Installer

1. Ouvrez la dernière exécution du workflow **Windows** sur GitHub (onglet *Actions*) et téléchargez l'artefact `Wisper-Windows-Setup`.
2. Décompressez-le et lancez `Wisper-Setup-….exe`. L'installateur n'est pas signé : Windows SmartScreen affichera « Windows a protégé votre PC ». Cliquez sur **Informations complémentaires** puis **Exécuter quand même**.
3. Au premier lancement, collez votre **clé OpenRouter** dans *Réglages*. Elle est chiffrée avec la protection de données de Windows.

## Utiliser

| Action | Raccourci par défaut |
| --- | --- |
| Dicter : maintenez, parlez, relâchez, le texte est collé | `Ctrl + Win` |
| Modifier le texte sélectionné à la voix (dites la consigne) | `Ctrl + Win + E` (maintenir) |
| Réécrire le texte sélectionné | `Ctrl + Win + R` (appui) |

Les raccourcis se changent dans *Réglages*. La touche Fn n'existe pas sous Windows. Un raccourci qui se prolonge par une autre touche (par exemple `Ctrl + Win + →` pour changer de bureau) annule la dictée en cours.

## Ce qui rend la dictée rapide

- **Transcription par phrases pendant que vous parlez** : à chaque pause, la phrase part au fournisseur. Au relâchement, il ne reste que la dernière.
- **Fish Audio via OpenRouter** pour la transcription (`fish-audio/transcribe-1`).
- **Nettoyage IA en requêtes parallèles** : si le modèle principal tarde, le modèle de secours démarre sans attendre l'échec du premier.
- **Phrases courtes sans nettoyage** (6 mots par défaut, réglable).
- **Connexion préchauffée** vers le fournisseur dès le début de l'appui.
- La carte *Dernière dictée* de l'Accueil montre le temps de chaque étape, et deux tests mesurent la vitesse et la régularité des moteurs.

## Différences avec la version Mac

- Pas de mémoire sémantique, d'assistant IA vocal ni de pointeur visuel (version Mac seulement pour l'instant).
- La sélection est lue par un Ctrl+C temporaire : un marqueur est placé dans le presse-papiers pour être certain qu'une sélection existe, puis votre presse-papiers est restauré. Dans de rares éditeurs, Ctrl+C sans sélection copie la ligne entière.
- Le texte est collé avec Ctrl+V. Une application lancée en administrateur ne reçoit le collage que si Wisper l'est aussi.
- Les statistiques n'indiquent pas l'application utilisée.

## Confidentialité

Votre audio part chez OpenRouter, puis chez Fish Audio, pour être transcrit ; le texte part chez OpenRouter pour la réécriture. Rien d'autre n'est envoyé. L'historique (20 dernières dictées) est stocké sur ce PC et peut être désactivé. Les statistiques sont de simples compteurs sans texte.

## Développer

```bash
cd windows
npm ci
npm test            # tests unitaires (Node)
npm start           # lance l'application
npm run dist        # construit l'installateur dans windows/dist
```

`npx electron . --smoke-test` lance l'application, exerce l'interface et le réseau contre un faux fournisseur local, puis quitte. Avec `WISPER_SEED=1 WISPER_SCREENSHOT_DIR=…` il enregistre aussi des captures d'écran avec des données fictives.
