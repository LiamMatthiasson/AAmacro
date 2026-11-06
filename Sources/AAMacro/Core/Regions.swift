import CoreGraphics

/// Screen regions as fractions of the whole Roblox window (title bar included,
/// origin top-left). Measured from screenshots; fractions of the window, valid at any size with this shape (1320×832); they stay valid
/// because WindowManager locks the window to that size.
enum Region {
    // Lobby
    /// Left HUD column with Units / Store / Items / Play / Trade …
    static let lobbyHUD       = CGRect(x: 0.00, y: 0.35, width: 0.16, height: 0.40)
    /// Big centered popups: "Join Matchmaking?" and the code entry box.
    static let centerPopup    = CGRect(x: 0.20, y: 0.15, width: 0.60, height: 0.75)
    /// The event board in the summer area (shows which map is up, e.g. "Magic Town").
    static let eventBoard     = CGRect(x: 0.25, y: 0.10, width: 0.50, height: 0.35)

    // Stage
    /// "Vote start: 0/6  Yes / No" box at top center.
    static let voteBox        = CGRect(x: 0.35, y: 0.05, width: 0.30, height: 0.25)
    /// Path minimap, bottom right. Its path shape identifies the map regardless of camera.
    static let minimap        = CGRect(x: 0.845, y: 0.765, width: 0.145, height: 0.22)
    /// Yen counter above the hotbar ("21664¥"). Income pop-ups ("+85") float just above it,
    /// so the reader picks the bottom-most line and ignores lines starting with "+".
    static let yenCounter     = CGRect(x: 0.40, y: 0.78, width: 0.20, height: 0.095)
    /// "Magic Town  Summer Hunt" title at the top of every stage.
    static let stageTitle     = CGRect(x: 0.28, y: 0.06, width: 0.46, height: 0.085)   // just above the base health bar
    /// Right-side "Level info" panel (enemies remaining, modifiers). TODO: wave counter location.
    static let levelInfo      = CGRect(x: 0.79, y: 0.26, width: 0.19, height: 0.32)
    /// "Wave 26" under the stage title (the "+1132" pearls line below it is excluded).
    static let waveCounter    = CGRect(x: 0.22, y: 0.08, width: 0.20, height: 0.14)    // "Wave 15" (moves down when a boss bar shows)

    // Weather card vote ("The weather shifts…"): 3 cards, then a Vote button.
    static let cardScreen     = CGRect(x: 0.30, y: 0.24, width: 0.40, height: 0.07)   // "The weather shifts…"
    static let cardArea       = CGRect(x: 0.23, y: 0.33, width: 0.56, height: 0.40)
    static let cardColumnsX: [Double] = [0.323, 0.508, 0.693]
    static let cardVoteBar    = CGRect(x: 0.35, y: 0.76, width: 0.30, height: 0.12)   // "Vote ends in" + Vote/Cancel

    // Unit panel (bottom-left) after clicking a placed unit.
    static let unitPanel      = CGRect(x: 0.00, y: 0.37, width: 0.30, height: 0.33)
    static let unitPanelClose = NormPoint(x: 0.293, y: 0.388)

    // Hotbar: 6 unit slots; each shows its placement cost ("1200 ¥") near the bottom.
    static let hotbarSlotX: [Double] = [0.338, 0.406, 0.470, 0.536, 0.601, 0.667]
    /// Unit name under each hotbar slot ("Elf Mage (Aura)").
    static func slotName(_ slot: Int) -> CGRect {
        let x = hotbarSlotX[max(0, min(5, slot - 1))]
        return CGRect(x: x - 0.035, y: 0.925, width: 0.075, height: 0.035)
    }
    /// The F "Unit Overview" panel on the right.
    static let unitOverview = CGRect(x: 0.62, y: 0.06, width: 0.38, height: 0.72)

    /// The "0/1" / "4/4" placement counter that appears above a slot while you hold that unit.
    static func slotCounter(_ slot: Int) -> CGRect {
        let x = hotbarSlotX[max(0, min(5, slot - 1))]
        return CGRect(x: x - 0.04, y: 0.835, width: 0.09, height: 0.055)
    }

    static func slotCost(_ slot: Int) -> CGRect {
        let x = hotbarSlotX[max(0, min(5, slot - 1))]
        return CGRect(x: x - 0.01, y: 0.92, width: 0.05, height: 0.04)
    }
}
