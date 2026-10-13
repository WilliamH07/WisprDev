# Wisper Agent pour Safari

Agent intégré à la page web : appuyez deux fois sur **Ctrl** pour ouvrir un
panneau dans la page, posez une question, et l'agent répond à partir de la
page, de votre sélection et d'une bibliothèque de PDF. Le même geste referme
le panneau. Usage personnel, macOS et Safari uniquement ; l'extension n'est ni
signée ni publiée.

## Installation

1. Compilez Wisper avec l'extension et lancez l'app une fois :

   ```bash
   make SAFARI_AGENT=1 ARCH="$(uname -m)" CODESIGN_IDENTITY=-
   open "build/Wisper Dev.app"
   ```

2. Safari → Réglages → Avancés : cochez « Afficher les fonctionnalités pour
   les développeurs web ».
3. Menu Développement → « Autoriser les extensions non signées ». Safari
   désactive ce réglage à chaque redémarrage : il faut le recocher.
4. Safari → Réglages → Extensions : activez « Wisper Agent » et autorisez-la
   sur tous les sites web.
5. Wisper → Réglages → Agent Safari : activez l'agent et copiez le code
   d'appairage.
6. Cliquez sur l'icône Wisper Agent dans la barre d'outils de Safari et collez
   le code.

## Fonctionnement

```
Page Safari ── content.js (panneau, double Ctrl, extraction du texte)
   │  runtime.connect
background.js ── HTTP local, jeton d'appairage, réponse en flux (SSE)
   │  http://127.0.0.1:47821
Wisper.app ── SafariAgentService : contexte, bibliothèques PDF, OpenRouter
```

- **Contexte de page** : seul le texte lisible est extrait (zone principale,
  sans navigation, pied de page, publicités, scripts ni éléments cachés). Les
  champs de formulaire ne fournissent que leur libellé, jamais leur valeur,
  sauf le champ que vous sélectionnez ; les champs mot de passe ne sont jamais
  lus. L'URL est envoyée sans paramètres ni fragment.
- **Budget** : si la page dépasse le budget (6 000 tokens par défaut), Wisper
  garde le plan, la partie visible, votre sélection et les sections les plus
  proches de la question (BM25, local).
- **Bibliothèques** : dossiers de PDF définis dans Wisper. Les PDF sont lus
  dès leur ajout (PDFKit, reconnaissance de texte Vision pour les scans) et
  découpés en passages ; seuls les passages pertinents sont envoyés, avec leur
  page pour la citation. Rien d'autre que la liste des fichiers n'est
  enregistré.
- **Vitesse** : extraction de la page dès le premier appui sur Ctrl, connexion
  au fournisseur préchauffée à l'ouverture du panneau, préfixe de prompt
  stable par conversation pour profiter du cache des fournisseurs, routage
  OpenRouter vers le fournisseur le plus rapide, réponse affichée au fil de
  l'eau.
- **Isolation** : le panneau vit dans la page (Shadow DOM fermé). Les frappes
  et clics dans le panneau ne sont pas transmis aux scripts de la page, pour
  éviter que les raccourcis du site se déclenchent et que le site lise ce que
  vous écrivez à l'agent.
- **Sécurité du serveur local** : écoute uniquement sur 127.0.0.1, désactivé
  par défaut, chaque requête doit porter le jeton d'appairage, les origines web
  et les en-têtes Host inattendus sont refusés.
