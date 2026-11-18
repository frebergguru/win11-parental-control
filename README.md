# Foreldrekontroll for Windows 11

Et interaktivt skript som setter opp foreldrekontroll på en Windows 11-PC med Windows sine egne verktøy. Ingen ekstra programvare, ingen konto i skyen, og alt kan fjernes igjen fra menyen.

> **English summary:** An interactive PowerShell script (menus in Norwegian) that sets up parental control on Windows 11 using only built-in Windows features: a standard child account, screen time with warnings and automatic logoff, an app allowlist that blocks installing new apps and games (AppLocker on Pro/Education/Enterprise, Software Restriction Policies on Home), Wi-Fi network filters, a family DNS filter with forced SafeSearch and browser policies, and VPN/proxy blocking. Everything can be undone from the menu. Run `Start-Foreldrekontroll.cmd` as an administrator. Licensed under MIT.

## Kom i gang

1. Kopier hele mappen til PC-en (alle filene må ligge sammen).
2. Logg inn med en **administratorkonto** (din, ikke barnets).
3. Dobbeltklikk `Start-Foreldrekontroll.cmd` og godta spørsmålet om administratorrettigheter.
4. Velg **H** (hurtigoppsett) første gang.

Skriptet kopierer seg selv til `C:\Program Files\Foreldrekontroll\`. Senere endringer gjør du ved å kjøre `Start-Foreldrekontroll.cmd` derfra.

## Hva den gjør

| Meny | Hva | Hvordan |
|---|---|---|
| 1 Barnekontoer | Egen standardkonto for barnet (aldri administrator) | `New-LocalUser`, grupper slås opp med SID, så det virker på norsk Windows |
| 2 Skjermtid | Tidsrom per dag og maks minutter per dag, varsel 10, 5 og 1 minutt før, utlogging | Planlagt oppgave som kjører `Haandhever.ps1` som SYSTEM hvert minutt, pluss påloggingstider på kontoen |
| 3 Apper og spill | Barnet kan ikke installere eller kjøre nye programmer; du velger hvilke installerte apper og spill som er tillatt | AppLocker (Pro, Education, Enterprise) eller Software Restriction Policies (Home); Microsoft Store, winget og Xbox-appen sperres; kommandolinje og PowerShell sperres for barnet; "Kjør som administrator" avvises automatisk |
| 4 Trådløse nettverk | Bare tillatte nettverk, eller sperrede nettverk | `netsh wlan add filter`; kan også hindre nye nettverkskort (USB-deling fra mobil) og slå av Bluetooth-nettverk. Nettverk som heter **Anlegg** pluss et tall (Anlegg1, Anlegg2 og så videre) er alltid sperret som standard: 1 til 50 sperres med en gang, og håndheveren sperrer høyere tall når de dukker opp. Navnene kan endres i menyen |
| 5 Nettfilter | Voksensider sperres, SafeSearch og YouTube begrenset modus | Familie-DNS (CleanBrowsing Family som standard, eller Cloudflare for Families) på alle nettverkskort; andre DNS-tjenere sperres i brannmuren; nettleserregler for Edge, Chrome, Brave og Firefox (ingen privat modus, ingen utvidelser, ingen egen DNS) |
| 6 VPN og proxy | VPN kan ikke brukes | Windows sin innebygde VPN slås av, VPN-porter sperres i brannmuren, proxy kan bare endres av administrator, VPN-sidene i Innstillinger skjules for barnet |
| 7 Ekstra sikring | Hindrer vanlige triks | Barnet kan ikke bytte tidssone; regedit sperres; valgfritt å slå av gjenopprettingsmiljøet (sikkermodus) |
| 8 Ekstra tid | Gi barnet flere minutter i dag | Gjelder bare i dag, og forlenger også siste klokkeslett |
| 9 Status | Viser hva som faktisk er satt | |
| 10 Bruk på nytt | Setter alt på nytt fra lagrede innstillinger | Nyttig etter store Windows-oppdateringer |
| 11 Fjern | Fjerner alt og setter tilbake det som var | Spør før barnekontoen eventuelt slettes |

Innstillingene lagres i `C:\Program Files\Foreldrekontroll\config.json`. Barnet kan lese, men ikke endre filene der.

## Kjente begrensninger

- **Gjelder hele PC-en:** DNS-filteret, Wi-Fi-filteret og VPN-sperren gjelder også voksne. Trenger du selv VPN, slår du det av i meny 6.
- **Windows Home** har ikke AppLocker. Skriptet bruker da Software Restriction Policies, som Microsoft ikke lenger utvikler videre. Test at sperren virker (se under). Store-appen fjernes for barnet i stedet for å sperres; for å få den tilbake etter "Fjern", logg inn som barnet og kjør `wsreset -i`.
- **Steam, Epic og lignende:** Er klienten tillatt for barnet, kan barnet hente gratisspill inne i den. Bruk Steam Family View / Epic sin foreldrekontroll i tillegg. Steam sin mappe er skrivbar for alle brukere, så skriptet sperrer den som standard.
- **OneDrive** ligger i brukerens egen mappe og blir derfor sperret for barnet.
- **Sikkermodus og oppstart fra USB** kan bare stoppes helt med BIOS/UEFI-passord, slått av USB-oppstart og BitLocker.
- **Nettlesere uten regelstøtte** (for eksempel Opera) som en voksen har installert, bør sperres i meny 3.
- **Nye nettverkskort sperret** (meny 4) kan også stoppe driveroppdateringer for nettverkskort. Slå det av midlertidig når du skal oppdatere drivere.

## Slik tester du at det virker

Logg inn som barnet og prøv:

1. Last ned et program (for eksempel et installasjonsprogram) og start det fra Nedlastinger. Det skal sperres.
2. Åpne Microsoft Store og kommandolinjen. Begge skal sperres.
3. Åpne en voksenside og søk med Google eller Bing. Siden skal sperres og SafeSearch skal være på.
4. Prøv å koble til et nettverk som ikke er tillatt.
5. Prøv å legge til en VPN i Innstillinger.
6. Sett skjermtiden lavt i meny 2 og se at varsel og utlogging kommer.

Logg så inn som voksen, velg **11** og kontroller med **9** at alt er borte.

## Filer

- `Setup-Foreldrekontroll.ps1`: menyen og alt oppsettet (PowerShell 5.1, som følger med Windows 11)
- `Haandhever.ps1`: kjøres hvert minutt som SYSTEM (skjermtid og DNS)
- `Start-Foreldrekontroll.cmd`: starter oppsettet som administrator

## Lisens

MIT, se [LICENSE](LICENSE). Bruk på eget ansvar, og test på en PC du kan sette tilbake.
