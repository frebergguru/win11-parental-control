# Foreldrekontroll for Windows 11

Et interaktivt skript som setter opp foreldrekontroll på en Windows 11-PC med Windows sine egne verktøy. Ingen ekstra programvare, ingen konto i skyen, og alt kan fjernes igjen fra menyen.

> **English summary:** An interactive PowerShell script (menus in Norwegian or Ukrainian) that sets up parental control on Windows 11 using only built-in Windows features: a standard child account, screen time with warnings and automatic logoff, an app allowlist that blocks installing new apps and games (AppLocker on Pro/Education/Enterprise, Software Restriction Policies on Home), Wi-Fi network filters, a family DNS filter with forced SafeSearch and browser policies, and VPN/proxy blocking. Everything can be undone from the menu. The menus are available in Norwegian and Ukrainian ([README.uk.md](README.uk.md)). Run `Start-Foreldrekontroll.cmd` as an administrator. Licensed under MIT.

Skriptet kan brukes på **norsk** eller **ukrainsk**. Språket velges første gang, og kan byttes med **L** i hovedmenyen. Det ukrainske grensesnittet virker på norsk, engelsk og alle andre språkversjoner av Windows 11, og menybokstavene (H, L, G, S, X, M) kan også tastes med ukrainsk tastaturoppsett. Українська версія цього посібника: [README.uk.md](README.uk.md).

## Kom i gang

1. Kopier hele mappen til PC-en (alle filene, også mappen `lang`, må ligge sammen).
2. Logg inn med en **administratorkonto** (din, ikke barnets).
3. Dobbeltklikk `Start-Foreldrekontroll.cmd` og godta spørsmålet om administratorrettigheter.
4. Velg språk, og deretter **H** (hurtigoppsett) første gang.

Skriptet kopierer seg selv til `C:\Program Files\Foreldrekontroll\`. Senere endringer gjør du ved å kjøre `Start-Foreldrekontroll.cmd` derfra.

## Spørsmål og svar

**Må barnets brukerkonto lages før jeg kjører skriptet?**
Nei. Skriptet lager kontoen selv: i hurtigoppsettet (H) eller i meny 1 velger du «Lag ny barnekonto», skriver brukernavn, fullt navn og eventuelt et passord, og skriptet lager en lokal standardkonto (ikke administrator). Barnet trenger ikke logge på først; skriptet lager brukerprofilen selv, så alle sperrene kan settes med en gang.

Har barnet allerede en konto på PC-en, velger du den i stedet («Velg en konto som finnes»). Er den kontoen administrator, gjør skriptet den om til standardbruker (bare hvis det finnes en annen administrator). Vil du at barnet skal bruke en Microsoft-konto, legger du den først til i Windows-innstillingene, og velger den deretter i meny 1.

Du må selv ha en **administratorkonto** med et passord barnet ikke kjenner. Det er den du kjører skriptet fra.

**Hvis du vil lage kontoen selv (ikke nødvendig)**

Det trengs bare hvis barnet skal ha en Microsoft-konto, eller hvis du heller vil gjøre det i Windows. Navnene på knappene kan variere litt mellom Windows-versjoner; de engelske navnene står i parentes.

*Microsoft-konto for barnet:*

1. Logg på med administratorkontoen din.
2. Åpne **Innstillinger > Kontoer > Familie** (Settings > Accounts > Family).
3. Velg **Legg til noen** (Add someone), og følg veiviseren for å lage en ny Microsoft-konto for barnet (eller skriv inn e-postadressen til en konto barnet allerede har).
4. Logg på med barnets konto én gang, og logg ut igjen.
5. Kjør skriptet, og velg barnets konto i meny 1 («Velg en konto som finnes»).

*Lokal konto (uten Microsoft-konto):*

1. Åpne **Innstillinger > Kontoer > Andre brukere** (Settings > Accounts > Other users).
2. Velg **Legg til konto** (Add account).
3. Velg **Jeg har ikke påloggingsinformasjonen for denne personen** (I don't have this person's sign-in information), og deretter **Legg til en bruker uten Microsoft-konto** (Add a user without a Microsoft account).
4. Skriv brukernavn og passord, og fullfør.
5. Kjør skriptet, og velg kontoen i meny 1 («Velg en konto som finnes»).

Windows lager slike kontoer som standardbrukere. Skriptet sjekker det uansett, og gjør om kontoen hvis den er administrator.

## Hva den gjør

| Meny | Hva | Hvordan |
|---|---|---|
| 1 Barnekontoer | Egen standardkonto for barnet (aldri administrator) | `New-LocalUser`, grupper slås opp med SID, så det virker på alle språkversjoner av Windows |
| 2 Skjermtid | Tidsrom per dag og maks minutter per dag, varsel 10 og 3 minutter før, utlogging | Planlagt oppgave som kjører `Haandhever.ps1` som SYSTEM hvert minutt, pluss påloggingstider på kontoen |
| 3 Apper og spill | Barnet kan ikke installere eller kjøre nye programmer; du velger hvilke installerte apper og spill som er tillatt | AppLocker (Pro, Education, Enterprise) eller Software Restriction Policies (Home); Microsoft Store, winget og Xbox-appen sperres; kommandolinje og PowerShell sperres for barnet; "Kjør som administrator" avvises automatisk |
| 4 Trådløse nettverk | Bare tillatte nettverk, eller sperrede nettverk | `netsh wlan add filter`; kan også hindre nye nettverkskort (USB-deling fra mobil) og slå av Bluetooth-nettverk. Nettverk som heter **Anlegg** pluss et tall (Anlegg1, Anlegg2 og så videre) er alltid sperret som standard, i alle moduser: 1 til 50 og 01 til 09 sperres med en gang, skrevet som Anlegg, ANLEGG og anlegg, og håndheveren sperrer høyere tall når de dukker opp (og kobler fra hvis PC-en er koblet til et slikt nettverk). Slike navn kan aldri tillates. Navnene kan endres i menyen |
| 5 Nettfilter | Voksensider sperres, SafeSearch og YouTube begrenset modus | Familie-DNS (CleanBrowsing Family som standard, eller Cloudflare for Families) på alle nettverkskort; andre DNS-tjenere sperres i brannmuren; nettleserregler for Edge, Chrome, Brave og Firefox (ingen privat modus, ingen utvidelser, ingen egen DNS) |
| 6 VPN og proxy | VPN kan ikke brukes | Windows sin innebygde VPN slås av, VPN-porter sperres i brannmuren, proxy kan bare endres av administrator, VPN-sidene i Innstillinger skjules for barnet |
| 7 Ekstra sikring | Hindrer vanlige triks, og holder alt på plass etter Windows-oppdateringer | Barnet kan ikke bytte tidssone; regedit sperres; valgfritt å slå av gjenopprettingsmiljøet (sikkermodus); alt brukes automatisk på nytt etter Windows-oppdateringer (se under) |
| 8 Ekstra tid | Gi barnet flere minutter i dag | Gjelder bare i dag, og forlenger også siste klokkeslett |
| 9 Status | Viser hva som faktisk er satt | |
| 10 Bruk på nytt | Setter alt på nytt fra lagrede innstillinger | Nyttig etter store Windows-oppdateringer, eller etter at en ny voksenkonto er lagt til |
| 11 Fjern | Fjerner alt og setter tilbake det som var | Spør før barnekontoen eventuelt slettes |

Innstillingene lagres i `C:\Program Files\Foreldrekontroll\config.json`. Barnet kan lese, men ikke endre filene der.

Meldingene barnet ser (varsler om skjermtid), vises på språket de voksne har valgt.

## Etter Windows-oppdateringer

Store Windows-oppdateringer kan tilbakestille noen innstillinger. Derfor finnes en egen planlagt oppgave, **Foreldrekontroll etter oppdatering**, som kjører som SYSTEM ved hver oppstart (etter 3 minutter) og én gang om dagen:

- Den sammenligner Windows-versjonen (byggnummer og oppdateringsnummer) med forrige gang. Har Windows blitt oppdatert, brukes alle innstillinger på nytt, akkurat som meny 10.
- Den sjekker også at de viktigste sperrene fortsatt er på plass (håndhever-oppgaven, AppLocker-reglene og -tjenesten, brannmurreglene og VPN-tjenestene). Mangler noe, brukes alt på nytt.
- Ellers gjør den ingenting, så den koster nesten ingenting de fleste dager.
- Den endrer bare det som faktisk mangler eller er annerledes, så Wi-Fi-tilkoblingen og nettspill ikke blir avbrutt. Lykkes ikke alt, prøver den igjen dagen etter (ikke hver gang).
- Innstillingene lagres trygt: forrige versjon ligger som `config.json.bak`, og er filen skadet (for eksempel etter strømbrudd), brukes sikkerhetskopien. Kan ingen av dem leses, endres ingenting.
- Hva den har gjort, står i `C:\Program Files\Foreldrekontroll\etter-oppdatering.log`, og i status (meny 9).

Dette er på som standard og kan slås av i meny 7. Voksne som har kjørt skriptet, huskes, så kontoene deres aldri blir behandlet som barn når innstillingene brukes på nytt automatisk.

## Spill (Fortnite, Battlefield og andre)

Skriptet er laget for at spill skal virke og ikke bli tregere:

- **Ingen ytelsestap i spill:** AppLocker sjekker bare når et program starter (DLL-regler er ikke slått på, de ville kostet ytelse). Håndheveren kjører med lav prioritet, bruker under ett sekund hvert minutt og kompilerer ingenting etter første kjøring. DNS endres bare når den faktisk er feil, høyst én gang i timen per nettverkskort, så det blir ingen nettverkshikk mens barnet spiller.
- **Spill, spillklienter og antijuks tillates:** I meny 3 (og i hurtigoppsettet) finner skriptet Steam, Epic (Fortnite), EA app (Battlefield), Battle.net, Ubisoft og antijuks som Easy Anti-Cheat, BattlEye og EA Javelin. Velg **G** for å tillate alle. Hele spillmappen tillates, så oppdateringer og hjelpeprogrammer i spillmappen virker.
- **Brannmuren rører ikke spilltrafikk:** Bare DNS-portene til kjente offentlige DNS-tjenere og vanlige VPN-porter sperres. UDP 500 og 4500 er åpne, fordi Xbox-nettverket (partychat, Teredo, krysspill) bruker dem. Ping til for eksempel 8.8.8.8 virker fortsatt.
- **Bare to varsler:** Varselvinduene kan ta fokus fra et spill i fullskjerm, derfor kommer de bare 10 og 3 minutter før tiden er ute.

Gode vaner:

1. Installer nye spill fra **din** konto, og start hvert spill én gang der. Da blir antijuks, DirectX og andre tillegg installert med administratorrettigheter, som barnet ikke har.
2. Etter at du har installert et nytt spill: kjør meny 3 og velg **G** igjen, så blir det nye spillet tillatt.
3. Vil et spill ikke starte for barnet, se i **Hendelsesliste** (eventvwr.msc) **> Logger for programmer og tjenester > Microsoft > Windows > AppLocker** hva som ble stoppet, og tillat mappen med **M** i meny 3. Hjelper ikke det, prøv å slå av "Sperre kommandolinje" i meny 3.
4. Discord og andre programmer som installeres i brukerens egen mappe blir sperret. Bruk nettleserversjonen, eller installer en versjon for alle brukere fra din konto.

## Kjente begrensninger

- **Gjelder hele PC-en:** DNS-filteret, Wi-Fi-filteret og VPN-sperren gjelder også voksne. Trenger du selv VPN, slår du det av i meny 6.
- **Windows Home** har ikke AppLocker. Skriptet bruker da Software Restriction Policies, som Microsoft ikke lenger utvikler videre, og som ifølge noen rapporter ikke alltid håndheves på nyere Windows 11. Test derfor alltid at sperren virker (test 1 under) før du stoler på den. Store-appen fjernes for barnet i stedet for å sperres; for å få den tilbake etter "Fjern", logg inn som barnet og kjør `wsreset -i`.
- **Steam, Epic og lignende:** Er klienten tillatt for barnet, kan barnet hente gratisspill inne i den. Bruk Steam Family View / Epic sin foreldrekontroll i tillegg. Alle brukere kan skrive i Steam-mappen. Den er sperret til du tillater den (G i meny 3 tillater den), og da kan barnet i teorien legge egne programmer der og kjøre dem. Vil du stenge det hullet, sperr Steam igjen i meny 3 og bruk bare spill som ikke trenger Steam.
- **OneDrive** ligger i brukerens egen mappe og blir derfor sperret for barnet.
- **Sikkermodus og oppstart fra USB** kan bare stoppes helt med BIOS/UEFI-passord, slått av USB-oppstart og BitLocker.
- **Nye kontoer:** Legger du til en ny voksenkonto etter oppsettet, kjør meny 10 (Bruk alle innstillinger på nytt), ellers behandles den som et barn av app-sperren.
- **Kjør som administrator** avvises automatisk for alle standardbrukere (ikke bare barnet) når det valget er på. Bruk administratorkontoen til endringer.
- **Nettlesere uten regelstøtte** (for eksempel Opera) som en voksen har installert, bør sperres i meny 3.
- **Wi-Fi-navn med høyere tall** enn Anlegg50 sperres bare automatisk når Windows kan vise nettverkene rundt PC-en. Fra Windows 11 24H2 krever det at posisjonstjenester er på. Anlegg1 til Anlegg50 (og 01 til 09, med store, små og vanlige bokstaver) er alltid sperret. Et skjult nettverk med et høyere tall eller en annen skrivemåte blir ikke oppdaget; bruk «bare tillatte nettverk» hvis det er en risiko.
- **Innebygde Windows-verktøy:** Noen innebygde verktøy (for eksempel rundll32) kan i teorien brukes til å kjøre egen kode. De kan ikke sperres uten at Windows slutter å virke som det skal.
- **Fjern** setter ikke tilbake alt: en barnekonto som var administrator, forblir standardbruker; gjestekontoen forblir av; slettede Wi-Fi-profiler må legges inn på nytt; og barnets policy-nøkler beholder skrivebeskyttelsen (den er ufarlig).
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
- `lang/uk.psd1`: ukrainske tekster (norsk tekst er nøkkelen)
- `tests/Test-Oversettelser.ps1`: sjekker at alle tekster er oversatt og at plassholderne stemmer
- `tests/Test-Logikk.ps1`: tester Wi-Fi-filtrene (særlig Anlegg1 til Anlegg50) mot en simulert netsh, konfigurasjonsfilene og AppLocker-reglene
- `tests/Test-EtterOppdatering.ps1`: tester når innstillingene brukes på nytt etter oppdateringer, og at oppgave-XML-en er gyldig
- `tests/Test-Kulturer.ps1`: kjører det ukrainske grensesnittet med norsk, engelsk og ukrainsk Windows-kultur (formatering, ja/nei-svar og menybokstaver fra ukrainsk tastatur)

## Lisens

MIT, se [LICENSE](LICENSE). Bruk på eget ansvar, og test på en PC du kan sette tilbake.
