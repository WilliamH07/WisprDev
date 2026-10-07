import Foundation

struct SemanticMemoryTests {
    static func run() {
        testSecurityFilter()
        testIntentDetectionAndExtraction()
        testStoreAndSearch()
        testTerminalHistoryParsing()
        testTerminalSecurityAndNoiseFilters()
        testTerminalSearchRetrieval()
        testEnglishNoiseFiltering()
        testManualNotes()
        testCaptureDefaults()
    }

    private static func testTerminalHistoryParsing() {
        // Plain format
        let plain = SemanticMemoryService.parseTerminalHistoryLine("docker compose build nas")
        assert(plain != nil, "Plain command must parse")
        assert(plain?.command == "docker compose build nas", "Parsed command must match")

        // Extended zsh format: : 1727712000:0;ssh admin@100.98.53.132
        let extended = SemanticMemoryService.parseTerminalHistoryLine(": 1727712000:0;ssh admin@100.98.53.132")
        assert(extended != nil, "Extended zsh line must parse")
        assert(extended?.command == "ssh admin@100.98.53.132", "Parsed command must extract command part")
        assert(extended?.date == Date(timeIntervalSince1970: 1727712000), "Date must match timestamp")

        // Empty line
        assert(SemanticMemoryService.parseTerminalHistoryLine("   ") == nil, "Empty line must return nil")
    }

    private static func testTerminalSecurityAndNoiseFilters() {
        let service = SemanticMemoryService.shared

        // Noise filtering
        assert(service.isNoiseTerminalCommand("ls"), "'ls' must be filtered as noise")
        assert(service.isNoiseTerminalCommand("cd .."), "'cd ..' must be filtered as noise")
        assert(service.isNoiseTerminalCommand("clear"), "'clear' must be filtered as noise")
        assert(service.isNoiseTerminalCommand("pwd"), "'pwd' must be filtered as noise")

        // Conversational pasted text filtering
        assert(service.isNoiseTerminalCommand("comment je peux avoir cette app sur mon iphone ?"), "Pasted question must be filtered as noise")
        assert(service.isNoiseTerminalCommand("Accueil : la coche ne chevauche plus la date."), "Pasted commit title with colon must be filtered as noise")
        assert(service.isNoiseTerminalCommand("En fait on va faire un test"), "Pasted conversational phrase must be filtered as noise")

        // Useful commands (NOT noise)
        assert(!service.isNoiseTerminalCommand("docker compose build nas"), "Docker command is not noise")
        assert(!service.isNoiseTerminalCommand("docker compose up -d --no-build processing server"), "Docker up command is not noise")
        assert(!service.isNoiseTerminalCommand("ssh admin@100.98.53.132"), "SSH command is not noise")
        assert(!service.isNoiseTerminalCommand("git commit -m 'Initial commit'"), "Git commit is not noise")

        // Sensitive credentials filtering
        assert(service.isSensitiveTerminalCommand("export GITHUB_TOKEN=ghp_1234567890"), "GitHub token must be filtered")
        assert(service.isSensitiveTerminalCommand("mysql -u root -p mySecretPassword"), "Password flag must be filtered")
        assert(service.isSensitiveTerminalCommand("curl -H 'Authorization: Bearer mytoken'"), "Bearer token must be filtered")

        // Non-sensitive commands
        assert(!service.isSensitiveTerminalCommand("docker compose up -d"), "Normal docker up is safe")
        assert(!service.isSensitiveTerminalCommand("tar -xzf ~/archive.tar.gz"), "Tar command is safe")
        assert(!service.isSensitiveTerminalCommand("mkdir -p /volume1/docker/nas"), "mkdir -p is safe")
        assert(!service.isSensitiveTerminalCommand("scp -p archive.tar.gz admin@100.98.53.132:archive.tar.gz"), "scp -p is safe")
        assert(!service.isSensitiveTerminalCommand("test -s secrets/tbm-public-api-key && docker compose build nas"), "secrets path check is safe")

        // Multiline extraction
        let multi = """
        docker run -d \\
          --name my-nas \\
          -p 8080:80 \\
          nginx:alpine
        echo hello
        """
        let extracted = SemanticMemoryService.extractCommands(from: multi)
        assert(extracted.count == 2, "Should extract 2 commands from multiline string, got \(extracted.count)")
        assert(extracted[0].command.contains("--name my-nas"), "Multiline flags should be joined")
        assert(extracted[1].command == "echo hello", "Plain command should be preserved")
    }

    private static func testTerminalSearchRetrieval() {
        let store = SemanticMemoryStore(inMemory: true)
        let service = SemanticMemoryService(store: store)

        let cmd1 = SemanticMemoryItem(
            text: "docker compose -f /volume1/docker/nas/docker-compose.yml up -d",
            sourceAppName: "Terminal",
            category: .terminal
        )
        let cmd2 = SemanticMemoryItem(
            text: "ssh admin@100.98.53.132 'sha256sum maverick-nas.tar.gz'",
            sourceAppName: "Terminal",
            category: .terminal
        )
        let cmd3 = SemanticMemoryItem(
            text: "npm run dev -- --port 3000",
            sourceAppName: "Terminal",
            category: .terminal
        )
        let cmd4 = SemanticMemoryItem(
            text: "docker compose up -d --no-build processing server",
            sourceAppName: "Terminal",
            category: .terminal
        )

        store.insert(cmd1, sync: true)
        store.insert(cmd2, sync: true)
        store.insert(cmd3, sync: true)
        store.insert(cmd4, sync: true)

        assert(store.count() == 4, "Store must contain 4 items")

        // Search for docker launch command
        let dockerResults = service.search(query: "quelle est la commande que j’ai tapé pour lancer le docker tout a l’heure ?")
        assert(!dockerResults.isEmpty, "Search for docker query must return results")
        assert(dockerResults[0].item.text.contains("docker compose up"), "Top result should be docker compose up command")

        // Search for nas command
        let results = service.search(query: "lancer le nas")
        assert(!results.isEmpty, "Search for 'lancer le nas' must return results")
        assert(results[0].item.text.contains("docker-compose.yml"), "Top result should be docker nas command")

        // Search for ssh nas
        let sshResults = service.search(query: "ssh nas")
        assert(!sshResults.isEmpty, "Search for 'ssh nas' must return results")
        assert(sshResults[0].item.text.contains("100.98.53.132"), "Top result should be ssh command")
    }

    private static func testSecurityFilter() {
        let service = SemanticMemoryService.shared

        // Password apps
        assert(service.isSensitiveContent("mysecret123", sourceApp: "1Password 7"), "1Password content must be sensitive")
        assert(service.isSensitiveContent("anotherSecret", sourceApp: "Bitwarden"), "Bitwarden content must be sensitive")
        assert(service.isSensitiveContent("tokenVal", sourceApp: "Keychain Access"), "Keychain Access content must be sensitive")

        // Private keys
        let rsaKey = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA..."
        assert(service.isSensitiveContent(rsaKey, sourceApp: "Terminal"), "Private keys must be sensitive")

        // High entropy password-like string
        let highEntropy = "xK9#mQ2$pL8@vN1!"
        assert(service.isSensitiveContent(highEntropy, sourceApp: "Notes"), "High-entropy secret string must be sensitive")

        // Ordinary user dictation & clipboard
        assert(!service.isSensitiveContent("Bonjour tout le monde !", sourceApp: "Slack"), "Normal sentence must not be sensitive")
        assert(!service.isSensitiveContent("curl -X POST https://api.example.com", sourceApp: "Terminal"), "Curl command must not be sensitive")
    }

    private static func testIntentDetectionAndExtraction() {
        assert(SemanticMemoryService.isMemorySearchQuery("Wisper, retrouve le numéro de commande"), "Trigger 'retrouve' must match")
        assert(SemanticMemoryService.isMemorySearchQuery("C'était quoi le code wifi ?"), "Trigger 'c'était quoi' must match")
        assert(SemanticMemoryService.isMemorySearchQuery("retrouve l'adresse"), "Trigger 'retrouve' must match")
        assert(SemanticMemoryService.isMemorySearchQuery("find my tracking number"), "Trigger 'find my' must match")

        assert(!SemanticMemoryService.isMemorySearchQuery("Je vais t'expliquer comment ça marche"), "Normal dictation must not trigger memory search")
        assert(!SemanticMemoryService.isMemorySearchQuery("Merci beaucoup pour votre aide."), "Normal greeting must not trigger memory search")

        let query1 = SemanticMemoryService.extractSearchQuery("Wisper retrouve le code de confirmation")
        assert(query1.lowercased().contains("code de confirmation"), "Query should extract core intent, got '\(query1)'")

        let query2 = SemanticMemoryService.extractSearchQuery("C'était quoi le restaurant italien")
        assert(query2.lowercased().contains("restaurant italien"), "Query should extract 'restaurant italien', got '\(query2)'")
    }

    private static func testStoreAndSearch() {
        let store = SemanticMemoryStore(inMemory: true)
        let service = SemanticMemoryService(store: store)

        assert(store.count() == 0, "Initial store count must be 0")

        let item1 = SemanticMemoryItem(
            text: "Le mot de passe du wifi des invités est BleuHorizon2024",
            sourceAppName: "Slack",
            category: .clipboard
        )
        let item2 = SemanticMemoryItem(
            text: "Numéro de suivi Chronopost pour le colis: FR984271892",
            sourceAppName: "Safari",
            category: .clipboard
        )
        let item3 = SemanticMemoryItem(
            text: "Idée de recette: gratin dauphinois aux courgettes",
            sourceAppName: "Notes",
            category: .dictation
        )

        store.insert(item1, sync: true)
        store.insert(item2, sync: true)
        store.insert(item3, sync: true)

        assert(store.count() == 3, "Store count should be 3, got \(store.count())")

        // Search for wifi
        let wifiResults = service.search(query: "wifi invités")
        assert(!wifiResults.isEmpty, "Search for 'wifi invités' should find matches")
        assert(wifiResults[0].item.text.contains("BleuHorizon2024"), "Top result should be wifi item")

        // Search for colis
        let colisResults = service.search(query: "colis chronopost")
        assert(!colisResults.isEmpty, "Search for 'colis chronopost' should find matches")
        assert(colisResults[0].item.text.contains("FR984271892"), "Top result should be Chronopost item")

        // Search for recette
        let recetteResults = service.search(query: "gratin courgettes")
        assert(!recetteResults.isEmpty, "Search for 'gratin courgettes' should find matches")
        assert(recetteResults[0].item.text.contains("dauphinois"), "Top result should be recipe item")

        // Test clear
        store.clearAll()
        assert(store.count() == 0, "Store count after clearAll should be 0")
    }

    private static func testEnglishNoiseFiltering() {
        let service = SemanticMemoryService.shared

        // Conversational pasted English text must be filtered as noise
        assert(service.isNoiseTerminalCommand("I think we should move the deadline to next Friday"), "English conversational line must be filtered as noise")
        assert(service.isNoiseTerminalCommand("Can you send me the mockups when they are ready"), "English question-like line must be filtered as noise")
        assert(service.isNoiseTerminalCommand("Thank you for the quick review!"), "English courtesy line must be filtered as noise")

        // Useful English commands (NOT noise)
        assert(!service.isNoiseTerminalCommand("brew install create-dmg"), "brew command is not noise")
        assert(!service.isNoiseTerminalCommand("git push origin main"), "git push command is not noise")
        assert(!service.isNoiseTerminalCommand("swiftc -o test main.swift"), "swiftc command is not noise")
    }

    private static func testManualNotes() {
        let store = SemanticMemoryStore(inMemory: true)
        let service = SemanticMemoryService(store: store)

        assert(service.addManualNote("   ") == false, "Empty note must be rejected")
        assert(store.count() == 0, "Empty note must not be stored")

        assert(service.addManualNote("Commande de déploiement du projet X: ./deploy.sh prod"), "Valid note must be accepted")
        assert(store.count() == 1, "Manual note must be stored")

        let stored = store.fetchRecent(limit: 10)
        assert(stored.count == 1, "fetchRecent should return the stored note")
        assert(stored[0].category == .manualNote, "Stored note must use the manualNote category")
        assert(stored[0].sourceAppName == "Note", "Stored note source app must be 'Note'")

        // Disabled memory must reject notes
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "semantic_memory_enabled")
        defaults.set(false, forKey: "semantic_memory_enabled")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "semantic_memory_enabled")
            } else {
                defaults.removeObject(forKey: "semantic_memory_enabled")
            }
        }

        assert(service.addManualNote("should not be stored") == false, "Notes must be rejected when memory is disabled")
        assert(store.count() == 1, "Disabled memory must not store the note")
    }

    private static func testCaptureDefaults() {
        let defaults = UserDefaults.standard
        let hadClipboard = defaults.object(forKey: "semantic_memory_capture_clipboard") != nil
        let hadTerminal = defaults.object(forKey: "semantic_memory_capture_terminal") != nil
        defer {
            if hadClipboard { defaults.removeObject(forKey: "semantic_memory_capture_clipboard") }
            if hadTerminal { defaults.removeObject(forKey: "semantic_memory_capture_terminal") }
        }
        defaults.removeObject(forKey: "semantic_memory_capture_clipboard")
        defaults.removeObject(forKey: "semantic_memory_capture_terminal")

        // Clipboard and Terminal capture must be strictly opt-in
        assert(SemanticMemoryService.shared.captureClipboardEnabled == false, "Clipboard capture must default to off")
        assert(SemanticMemoryService.shared.captureTerminalHistoryEnabled == false, "Terminal history capture must default to off")
    }
}
