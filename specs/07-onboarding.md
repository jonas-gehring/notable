# Spec 07 — Onboarding-Flow

> **Aufwand: M.** Führt neue Nutzer durch die Berechtigungen und den ersten Erfolg.
> Bewusst schlank — der
> Wert liegt in **geführter Berechtigungserteilung** und einem **ersten Diktat-Erfolg**,
> nicht in Marketing-Slides.

## 1. Ziel

Beim **allerersten Start** (und auf Wunsch erneut aufrufbar) ein Fenster, das:

1. in einem Satz erklärt, was Notable tut (Diktat + Meeting-Notizen, alles lokal),
2. die **fünf Berechtigungen** in sinnvoller Reihenfolge erklärt und direkt anfordert,
   mit Live-Status,
3. die **Push-to-talk-Taste** zeigt und ein **erstes Diktat** üben lässt („Halte ⌥ und sag
   einen Satz"),
4. kurz auf Meeting-Erkennung, Zusammenfassungs-Provider und Datenschutz hinweist.

Heute gibt es **keinen** Onboarding-Flow — nur den Permissions-Tab und den Mic-Prompt beim
Start (`AppDelegate.applicationDidFinishLaunching` → `requestMicrophoneIfNeeded`). Ein neuer
Nutzer — auch auf einem neuen Rechner — landet ohne Führung im Nichts.

## 2. Warum das für ein Personal-Tool zählt

Notable braucht **fünf** TCC-Berechtigungen, jede mit eigenem Fehlermodus, zwei davon
(Bildschirmaufnahme, Eingabeüberwachung) brauchen sogar einen **Neustart**. Ohne Führung
ist genau das die Stelle, an der man nach einem Clean-Install rätselt, warum
Diktat „nichts tut". Onboarding ist hier **Berechtigungs-UX**, kein Zierrat.

## 3. Architektur

- Neues `Window(id: "onboarding")` in `NotableApp.swift` (Muster wie „notes"/"stats"),
  **beim Start nach vorn geholt** (`NSApp.activate(ignoringOtherApps: true)` +
  `makeKeyAndOrderFront` — exakt der Fix, den das Settings-Fenster gerade bekommen hat;
  eine Menübar-Accessory-App öffnet Fenster sonst im Hintergrund).
- Trigger: `@AppStorage("didCompleteOnboarding") == false` in `applicationDidFinishLaunching`
  → Fenster öffnen statt (nur) des Mic-Prompts. Nach Abschluss Flag setzen.
- Erneut aufrufbar über Menü **„Einführung erneut zeigen"** (setzt nichts zurück, öffnet nur).
- Wiederverwendung: `PermissionsManager` liefert schon Live-Status, `canPrompt`, `request`,
  `openSystemSettings` und Deep-Links (`PermissionsSettingsView` ist die Vorlage). Onboarding
  ist im Kern ein **geführter, seitenweiser Wrapper** um dieselben Aufrufe — keine neue
  Permissions-Logik.

Ein `OnboardingModel` (`@MainActor ObservableObject`) hält den Seitenindex und beobachtet
`PermissionsManager`, damit „Weiter" erst freigibt, wenn die kritische Berechtigung der
Seite erteilt ist (weich — überspringbar, s. u.).

## 4. Seiten (Reihenfolge)

1. **Willkommen** — ein Satz Zweck, ein Satz Datenschutz („Audio bleibt auf deinem Mac.
   Nur Transkript-Text geht zur Zusammenfassung raus."). Ein „Los geht's".
2. **Mikrofon** — erklären, „Erlauben" (nutzt `permissions.request(.microphone)`). Ohne
   Mikro kein Diktat — das ist die eine wirklich harte Voraussetzung.
3. **Eingabeüberwachung + Bedienungshilfen** — für globalen Hotkey & Einfügen. Hinweis auf
   den nötigen **Neustart** (die bestehende Relaunch-Logik aus `PermissionsSettingsView`
   wiederverwenden), damit der Hotkey grün wird.
4. **Erstes Diktat** — zeigt die aktuelle PTT-Taste (`HotkeySpec.current.label`) und fordert
   zum Üben auf. **Erfolgs-Erkennung:** sobald `RecordingStore` ein erstes Diktat verzeichnet
   (oder `DictationController` einen erfolgreichen Paste meldet), Häkchen „Sitzt!". Das ist
   der Aha-Moment — wichtiger als jede Erklärung.
5. **Meetings (optional)** — kurz: Auto-Erkennung + „System Audio Recording"-Berechtigung
   erklären (der überraschende Bildschirmaufnahme-Prompt), Kalender optional. Klar machen,
   dass Meetings ohne diese Rechte einfach still bleiben.
6. **Zusammenfassung** — Provider wählen: Anthropic-API-Key **oder** Claude Code CLI. Verweist
   in die bestehende `SummarizationSettingsView`-Logik (Key sichern/testen, CLI-Status). Darf
   übersprungen werden — Diktat funktioniert ohne.
7. **Fertig** — „Alles in der Menüleiste. Statistik & Einstellungen dort." Flag setzen.

## 5. Prinzipien

- **Überspringbar, nicht erzwingend.** Jede Seite außer Mikrofon hat „Später". Ein
  Personal-Tool-Nutzer darf durchklicken; Onboarding blockiert nie den App-Start dauerhaft.
- **Ehrlich statt hübsch.** Klartext, was jede Berechtigung *tut* und was ohne sie *nicht*
  geht — dieselbe Haltung wie der Permissions-Tab-Footer.
- **Kein Fokusklau des Diktat-Tests.** Auf Seite 4 muss der Nutzer in eine *andere* App
  klicken, um zu diktieren — das Onboarding-Fenster darf (wie das Overlay) den Fokus nicht
  festhalten; sonst landet der Test-Text im Nichts. Entweder Hinweis „klick in TextEdit"
  oder das Fenster non-key stellen während des Tests.
- **Reduce-Motion / Dynamic Type / Light-Dark / VoiceOver** von Anfang an (Phase-7-Prinzip
  aus `PLAN.md`).

## 6. Edge Cases

- **Teil-erteilte Rechte vor Onboarding** (schon vergeben): Seiten zeigen „bereits
  erteilt", „Weiter" sofort frei — nichts doppelt anfordern.
- **Neustart mitten im Flow** (für Screen/Input): nach Relaunch dieselbe Seite wieder
  öffnen (Seitenindex in `@AppStorage` zwischenspeichern, bis „Fertig").
- **Nutzer schließt das Fenster früh:** Flag **nicht** setzen → beim nächsten Start wieder
  anbieten (einmalig), danach nicht mehr nerven; immer über Menü erreichbar.
- **Kein Provider konfiguriert am Ende:** ok — Meetings werden dann nicht zusammengefasst,
  aber transkribiert; das sagt Seite 6 klar.

## 7. Tests

- `OnboardingModel` (State): Seitenfortschritt; „Weiter"-Freigabe abhängig vom
  (gefakten) Permissions-Status; Skip-Pfade; Persistenz des Seitenindex über Relaunch.
- Erfolgs-Erkennung des ersten Diktats: Fake-Signal → Seite 4 quittiert.
- Kein UI-Snapshot-Zwang; manuelle Verifikation auf einem frischen TCC-Zustand (eigener
  macOS-Testnutzer) ist die ehrliche Abnahme, da TCC-Prompts nicht unit-testbar sind.

## 8. Umsetzungsschritte

1. `OnboardingModel` + Seiten-Enum + Tests.
2. `Window(id:"onboarding")` + Trigger-Flag + Vordergrund-Fix + Menüpunkt „Einführung
   erneut zeigen".
3. Seiten 1–3 (Willkommen + Kern-Permissions über `PermissionsManager`), Relaunch-Handling.
4. Seite 4 (Erstes Diktat mit Erfolgs-Erkennung).
5. Seiten 5–7 (Meetings/Provider/Fertig), an bestehende Settings-Logik andockend.
6. Zugänglichkeit + frischer-TCC-Durchlauf.

## 9. Nicht-Ziele

- Kein Account/Login (Personal-Tool, kein Backend).
- Keine Feature-Tour über jedes Detail — Menüleiste + Settings sind selbsterklärend genug.
- Keine Analytics/Telemetrie im Onboarding.
