# iptv4unifi: KPN-tv op een UniFi-router

**Versie 1.1.0 (2026-11-11)** · voor KPN, XS4ALL en Freedom · [Versies](#versies)

Met dit script werkt **KPN-tv** (ook via XS4ALL of Freedom, die het KPN-netwerk gebruiken) op een UniFi-router met UniFi OS, zoals de Dream Router 7 (UDR7), Dream Router (UDR), Dream Machine (UDM/Pro/SE), Cloud Gateway (UCG) of UXG. Het glasvezelkastje (ONT) gaat dan rechtstreeks in je UniFi-router; de KPN Box is niet nodig.

Het is een vervanger van [fabianishere/udm-iptv](https://github.com/fabianishere/udm-iptv), speciaal voor KPN, met een paar verbeteringen:

- **Overleeft firmware-updates.** Alles staat in `/data`, en via [unifi-on-boot](https://github.com/unredacted/unifi-on-boot) herstelt het zichzelf na een update, zonder opnieuw te installeren of te configureren.
- **Watchdog.** UniFi herschrijft bij elke wijziging de netwerkconfiguratie. Het script controleert elke 30 seconden of de tv-interface, het DHCP-adres, de NAT-regels en de IGMP-proxy er nog zijn, en herstelt wat ontbreekt.
- **Eén script.** Geen `.deb` of debconf: een wizard stelt een paar vragen en regelt de rest.
- **Overstap vanaf udm-iptv of udr-iptv.** De wizard herkent een bestaande installatie, neemt je LAN-instelling over en ruimt de oude installatie pas op als de tv met iptv4unifi werkt.
- **Veilig testen.** Met `iptv4unifi.sh test` draai je het tijdelijk, met automatische terugval.

> ⚠️ Dit is een hobbyproject. Het is niet van KPN en niet van Ubiquiti. Gebruik het op eigen risico, en maak eerst een backup van je UniFi-instellingen.

## Inhoud

1. [Hoe het werkt](#hoe-het-werkt)
2. [Voorwaarden](#voorwaarden)
3. [Internet instellen (KPN)](#internet-instellen-kpn)
4. [Netwerk voor de decoder](#netwerk-voor-de-decoder)
5. [Installeren](#installeren)
6. [Commando's](#commandos)
7. [Firmware-updates](#firmware-updates)
8. [Problemen oplossen](#problemen-oplossen)
9. [Veelgestelde vragen](#veelgestelde-vragen)
10. [Verwijderen](#verwijderen)
11. [Versies](#versies)

## Hoe het werkt

```
          Glasvezel
              │
        ┌───────────┐
        │  KPN ONT  │
        └───────────┘
              │   VLAN 6 = internet (PPPoE)
              │   VLAN 4 = tv (DHCP, IGMP-multicast)
        ┌───────────┐
        │  UniFi-   │   VLAN 6 → PPPoE                    (regelt UniFi)
        │  router   │   VLAN 4 → "iptv" + improxy         (regelt dit script)
        └───────────┘
              │ LAN (bijvoorbeeld een apart netwerk voor tv)
        ┌───────────┐
        │  Switch   │   IGMP snooping aan
        └───────────┘
              │
      ┌───────────────┐
      │ KPN-decoder(s)│
      └───────────────┘
```

1. Het script maakt op de WAN-poort een VLAN-interface `iptv` (VLAN 4) aan.
2. Het vraagt via DHCP een adres aan bij KPN, met vendor-class `IPTV_RG`. Zonder die waarde geeft KPN geen adres.
3. Het zet de routes naar de tv-servers die KPN via DHCP meegeeft (optie 121). Een default route via tv komt er nooit; je internet blijft dus via PPPoE lopen.
4. Het zet NAT naar de tv-servers van KPN, voor de tv-gids en terugkijken.
5. Het start **improxy**, de IGMP-proxy die standaard in UniFi OS zit. Die stuurt de zenderverzoeken van de decoder door naar KPN, en de tv-stream terug naar je LAN.

## Voorwaarden

- Een UniFi-router met **UniFi OS 2.x of nieuwer**, met de laatste firmware.
- Het **glasvezelkastje (ONT) van KPN** zit direct op de WAN-poort van de router (RJ45 of SFP+).
- **SSH** staat aan: UniFi → Settings → Control Plane → Console → SSH.
- Switches tussen de router en de decoder hebben **IGMP snooping** aan. Ze hoeven niet van Ubiquiti te zijn.
- Het ingebouwde **IGMP Proxy**-vinkje bij je internetverbinding in UniFi staat **uit**. Er kan maar één IGMP-proxy tegelijk draaien.
- **Passthrough VLANs** (UniFi Network 11.1+) staat **uit**. Zie [Veelgestelde vragen](#veelgestelde-vragen).

## Internet instellen (KPN)

UniFi → **Settings → Internet** → je WAN-verbinding:

| Instelling | Waarde |
|---|---|
| Port | de poort waar het glasvezelkastje in zit |
| VLAN ID | **6** |
| IPv4 Connection | **PPPoE** |
| Username | `internet` |
| Password | `internet` |
| IPv6 | DHCPv6, Prefix Delegation /48 (optioneel) |
| IGMP Proxy | **uit** |
| Passthrough VLANs | **uit** |

Werkt internet, ga dan verder. Het script vindt de WAN-poort zelf: het zoekt de poort waar VLAN 6 op draait.

## Netwerk voor de decoder

Je kunt de decoder op je gewone LAN (`br0`) aansluiten, maar een **apart netwerk** is netter. Dan komt de tv-stream niet op de rest van je netwerk.

UniFi → **Settings → Networks → Create New**:

| Instelling | Voorbeeld |
|---|---|
| Name | `IPTV` |
| VLAN ID | bijvoorbeeld `4` of `40`. Het nummer mag je zelf kiezen; het staat los van KPN's VLAN 4 |
| Gateway/Subnet | `192.168.20.1/24` |
| DHCP | Server |
| IGMP Snooping | **aan**, en voeg het netwerk toe aan de IGMP-snoopinglijst |

Zet daarna de switchpoort van de decoder op dit netwerk: **Native VLAN = IPTV**, **Tagged VLAN Management = Block All**.

In de router heet het netwerk `br<VLAN-ID>`, dus `br4` bij VLAN 4. De wizard laat alle bridges met hun IP-adres zien.

## Installeren

### Stap 1: SSH aanzetten op de router

1. Open UniFi → **Settings → Control Plane → Console** (in sommige versies **System → Advanced**).
2. Zet **SSH** aan en kies een wachtwoord.
3. De gebruikersnaam is altijd **`root`**.

Test of het werkt, vanaf je pc. Op Windows gebruik je PowerShell of Terminal, op Mac en Linux de Terminal:

```bash
ssh root@192.168.1.1          # vervang door het IP-adres van je router
```

De eerste keer vraagt SSH of je de sleutel vertrouwt. Antwoord `yes` en geef het wachtwoord. Je bent nu ingelogd als `root` en hebt alle rechten die nodig zijn. `sudo` is niet nodig.

### Stap 2: het script op de router zetten

Kies **één** van deze drie manieren.

**A. Direct downloaden op de router** (het makkelijkst, als het script op GitHub staat)

Ingelogd op de router:

```bash
curl -fsSL -o /tmp/iptv4unifi.sh https://raw.githubusercontent.com/hvklaveren/iptv4unifi/main/iptv4unifi.sh
```

**B. Kopiëren vanaf je pc met `scp`**

Download eerst `iptv4unifi.sh` naar je pc. Open dan op je pc een terminal **in de map waar `iptv4unifi.sh` staat**:

```bash
scp iptv4unifi.sh root@192.168.1.1:/tmp/
```

`scp` zit standaard in Windows 10/11 (PowerShell), macOS en Linux.

**C. Kopiëren met WinSCP of FileZilla** (met muis, voor Windows)

1. Maak een verbinding: protocol **SFTP**, host = IP-adres van de router, gebruiker **`root`**, wachtwoord = je SSH-wachtwoord.
2. Sleep `iptv4unifi.sh` naar de map **`/tmp`** op de router.

### Stap 3: rechten en voorbereiding

Log in op de router (`ssh root@192.168.1.1`) en voer uit:

```bash
sed -i 's/\r$//' /tmp/iptv4unifi.sh      # Windows-regeleindes verwijderen (kan altijd geen kwaad)
head -4 /tmp/iptv4unifi.sh                 # controle: hier moet "iptv4unifi 1.1.0" staan
```

**Over rechten:**
- Je hoeft zelf **geen `chmod`** te doen. Je start het script met `sh`, en dat werkt ook zonder uitvoerrechten.
- Bij de installatie kopieert het script zichzelf naar **`/data/iptv4unifi/iptv4unifi.sh`** en zet het zelf de juiste rechten: `755`, eigenaar `root`.
- Alles draait als **`root`**. Dat is nodig voor netwerkinterfaces, iptables en systemd, en op UniFi OS log je via SSH altijd als root in.
- Waarom de `sed`-regel? Is het bestand ooit op Windows geopend of opgeslagen, dan kan het Windows-regeleindes (`\r\n`) bevatten. Het script geeft dan vage fouten zoals `not found` of `syntax error`. De `sed`-regel haalt ze weg.

### Stap 4: starten

```bash
sh /tmp/iptv4unifi.sh setup
```

Na de installatie gebruik je altijd het vaste pad:

```bash
/data/iptv4unifi/iptv4unifi.sh status
/data/iptv4unifi/iptv4unifi.sh check
```

Het bestand in `/tmp` mag je daarna weggooien. `/tmp` wordt bij een herstart toch leeggemaakt.

### Wat de wizard doet

De wizard werkt in twee fasen.

**Fase 1: vragen en controleren. Er verandert nog niets.**

1. Hij ziet of **udm-iptv** of **udr-iptv** geïnstalleerd is. Die blijven gewoon draaien, en hun LAN-instelling wordt het standaardantwoord.
2. Hij zoekt de **WAN-poort**: de poort waar VLAN 6 op draait, of anders het apparaat onder de PPPoE-sessie.
3. Hij toont je **LAN-bridges** met hun IP-adres, en vraagt op welke de decoder(s) zitten.
4. Hij vraagt **hoeveel decoders** je hebt (zie [quickleave](#veelgestelde-vragen)).
5. Hij doet een **controle vooraf**: WAN, VLAN 4 vrij, tv-netwerk, IGMP snooping, apparaten en wifi op het tv-netwerk. Bij een **[FOUT]** stopt hij, tenzij je zelf kiest om toch door te gaan.

**Fase 2: jij kiest.**

| Keuze | Wat er gebeurt |
|---|---|
| **1) eerst testen** (aanbevolen) | iptv4unifi draait een paar minuten, en udm-iptv of udr-iptv wordt zo lang gepauzeerd. Daarna komt die **altijd** terug, ook bij Ctrl+C of een fout. Daarna vraagt de wizard of de tv werkte. Alleen bij **ja** wordt de oude installatie verwijderd en iptv4unifi geïnstalleerd. |
| 2) direct installeren | udm-iptv of udr-iptv verwijderen (met back-up, zie [Verwijderen](#verwijderen)) en iptv4unifi installeren |
| 3) alleen opslaan | alleen de instellingen in `/data/iptv4unifi/iptv4unifi.conf`; later testen met `iptv4unifi.sh test 10` |
| 4) afbreken | er verandert niets |

Na de installatie biedt de wizard aan **unifi-on-boot** te installeren, voor herstel na firmware-updates. Daarna draait hij nog één keer `check`.

Tijdens de test haal je 10 seconden de stroom van de decoder af, kijk je tv en zap je een paar keer.

## Commando's

Gebruik altijd het volledige pad: `/data/iptv4unifi/iptv4unifi.sh <commando>`.

| Commando | Wat het doet |
|---|---|
| `setup` | installatie vanaf nul, met wizard; ook voor de overstap van udm-iptv |
| `status` | tv-interface, KPN-adres, routes, NAT, actieve streams en log |
| `check` | alle voorwaarden controleren, verandert niets |
| `reconfigure` | WAN-poort, LAN-bridge, aantal decoders of proxy wijzigen |
| `decoders <n>` | aantal decoders opgeven; zet quickleave goed |
| `test [min]` | tijdelijk draaien zonder installatie (standaard 10 minuten) |
| `debug on\|off` | uitgebreide logging van de IGMP-proxy |
| `logs` | live meekijken in de log |
| `restart` | service herstarten |
| `uninstall` | service verwijderen; config blijft bewaard |
| `uninstall --purge` | alles verwijderen |
| `info` | uitleg over de werking, op de router zelf |
| `version` | versie en datum van het script, de config en de geïnstalleerde service |

### Bestanden

| Pad | Inhoud |
|---|---|
| `/data/iptv4unifi/iptv4unifi.sh` | het script |
| `/data/iptv4unifi/iptv4unifi.conf` | jouw instellingen |
| `/data/iptv4unifi/iptv4unifi.log` | log, wordt automatisch ingekort |
| `/data/on_boot.d/10-iptv4unifi.sh` | boot-hook voor herstel na firmware-updates |
| `/etc/systemd/system/iptv4unifi.service` | systemd-service |

## Firmware-updates

Bij een firmware-update vervangt Ubiquiti het systeem, maar `/data` blijft altijd staan. Is [unifi-on-boot](https://github.com/unredacted/unifi-on-boot) geïnstalleerd (de wizard biedt dat aan), dan gebeurt er bij de eerste opstart na een update dit:

1. unifi-on-boot draait `/data/on_boot.d/10-iptv4unifi.sh`;
2. die ziet dat de service ontbreekt en draait `iptv4unifi.sh install`;
3. de service staat er weer, met jouw instellingen en zonder vragen.

improxy hoort bij UniFi OS zelf en blijft na een update gewoon bestaan.

Controleer na een update met `iptv4unifi.sh status`. In `/data/iptv4unifi/iptv4unifi.log` zie je wat er bij het opstarten is gebeurd.

## Problemen oplossen

Begin altijd met:

```bash
/data/iptv4unifi/iptv4unifi.sh check
/data/iptv4unifi/iptv4unifi.sh status
```

`check` verandert niets en controleert:

| Onderdeel | Wat er gecontroleerd wordt |
|---|---|
| WAN | WAN-poort gevonden via VLAN 6, internet via PPPoE, VLAN 4 vrij (geen Passthrough), IP-forwarding |
| Router | IGMP-proxy aanwezig, multicast-routing in de kernel, udm-iptv of een andere IGMP-proxy actief, unifi-on-boot |
| Tv-netwerk | bridge bestaat en heeft een router-adres (geen VLAN Only), IGMP snooping aan, welke apparaten erop zitten (kabel of wifi, met hostnaam) |
| Wifi | waarschuwt als er wifi-apparaten op het tv-netwerk zitten (dan hangt er een SSID aan) |
| Tv | KPN-adres op `iptv` en het aantal actieve tv-streams |

Wat `check` niet kan zien, omdat het in de UniFi-controller staat, controleer je zelf:

- de switchpoort van de decoder: **Native VLAN** = je tv-netwerk, **Tagged** = Block All;
- **IGMP snooping** aan op alle switches tussen router en decoder;
- **IGMP Proxy** en **Passthrough VLANs** bij je internetverbinding: uit;
- geen **SSID** gekoppeld aan het tv-netwerk.

| Symptoom | Oorzaak en oplossing |
|---|---|
| `[FOUT] VLAN 4 bezet door: eth4.4` | **Passthrough VLANs** staat aan in UniFi. Zet het uit en klik op Apply. |
| `[FOUT] LAN-bridge br4 bestaat niet` | het netwerk van de decoder bestaat niet (meer), of heeft een ander VLAN-ID. Controleer het in UniFi en draai `iptv4unifi.sh reconfigure`. |
| `iptv` krijgt geen 10.x-adres | Staat internet op VLAN 6? Is VLAN 4 vrij? Heeft de ONT net een herstart gehad? Wacht dan een paar minuten. Werkte het eerder wel, dan helpt het soms om de ONT 1 minuut zonder stroom te zetten. |
| Wel een adres, maar geen beeld | Kijk of de decoder om zenders vraagt: `tcpdump -ni br4 igmp`. Zie je niets, dan zit de decoder niet in het juiste netwerk, of filtert een switch IGMP. |
| Beeld valt weg op decoder B als A zapt | Je hebt meer decoders: draai `iptv4unifi.sh decoders 2`. |
| Beeld bevriest na een paar minuten | IGMP snooping staat niet aan op dat netwerk of op een tussenliggende switch. |
| `[INFO] er draait al een IGMP-proxy` | udm-iptv draait nog, of het ingebouwde **IGMP Proxy** in UniFi staat aan. Zet dat uit. |

Handige commando's:

```bash
tcpdump -ni br4 igmp                     # vraagt de decoder om zenders?
tcpdump -ni iptv igmp                    # gaan die verzoeken naar KPN?
ip mroute show                           # (bron,groep) Iif: iptv Oifs: br4 = stream loopt
cat /proc/net/ip_mr_vif                  # BytesIn op iptv ≈ BytesOut op br4
```

(Vervang `br4` door je eigen LAN-bridge.)

## Veelgestelde vragen

**UniFi Network 11.1 heeft "Passthrough VLANs". Is dit script dan nog nodig?**
Voor KPN wel. Passthrough geeft VLAN 4 ongewijzigd door aan je LAN (bridged), en dan vraagt de decoder zelf een adres aan bij KPN. KPN antwoordt op VLAN 4 alleen aan een router die zich als `IPTV_RG` meldt. In een test op 11 november 2026 (Network 11.1.47 Early Access) kreeg de decoder via passthrough geen adres. Ook koppelde UniFi VLAN 4 niet zelf aan de bridge. Dat kan in latere versies veranderen.

**Wat is quickleave?**
Zapt de decoder, dan stopt de oude stream bij quickleave direct, zonder eerst te wachten. Dat zapt sneller. Met meer decoders gaat het mis: zapt decoder A, dan stopt ook de stream die decoder B nog bekijkt. Daarom:
- 1 decoder: quickleave **aan**;
- 2 of meer: quickleave **uit** (`iptv4unifi.sh decoders 2`).

**Werkt internet nog als het script stopt of vastloopt?**
Ja. Het script raakt PPPoE (VLAN 6) en je default route niet aan. In het ergste geval heb je tijdelijk geen tv.

**Kan ik udm-iptv en iptv4unifi naast elkaar draaien?**
Nee. Ze willen allebei VLAN 4 op de WAN-poort en de multicast-routing van de kernel. `setup` biedt aan udm-iptv te verwijderen.

**Welk VLAN-nummer moet mijn tv-netwerk hebben?**
Dat maakt niet uit. Alleen de VLAN 4 aan de WAN-kant (KPN) ligt vast. Je eigen netwerk mag ook bijvoorbeeld VLAN 40 zijn, of gewoon je standaard-LAN.

**Werkt dit met andere providers?**
Dit script is alleen voor KPN, en voor providers op het KPN-netwerk met dezelfde instellingen, zoals XS4ALL en Freedom. Andere providers kunnen udm-iptv gebruiken, dat profielen voor meerdere providers heeft.

## Verwijderen

```bash
/data/iptv4unifi/iptv4unifi.sh uninstall           # service weg, config blijft bewaard
/data/iptv4unifi/iptv4unifi.sh uninstall --purge   # alles weg
```

Back-ups die `setup` maakt van een vorige installatie:
- udm-iptv: `/data/udm-iptv.conf.bak`
- udr-iptv: `/data/udr-iptv.bak-<datum>/`

Terug naar udm-iptv:

```bash
/data/iptv4unifi/iptv4unifi.sh uninstall
sh -c "$(curl https://raw.githubusercontent.com/fabianishere/udm-iptv/master/install.sh -sSf)"
cp /data/udm-iptv.conf.bak /etc/udm-iptv.conf   # als je de oude config wilt terugzetten
udm-iptv restart
```

## Versies

Op de router zie je de versie met:

```bash
/data/iptv4unifi/iptv4unifi.sh version
```

Je ziet dan de versie van het script, met welke versie je config is gemaakt, en welke versie als service draait. Die versie staat ook bovenaan in `iptv4unifi.conf`, in de boot-hook, in de systemd-service en bij elke start in de log.

| Versie | Datum | Wijzigingen |
|---|---|---|
| **1.1.0** | 2026-11-11 | Alleen KPN (ook XS4ALL en Freedom), in het Nederlands. Overstap van udm-iptv én udr-iptv, pas na een geslaagde test. WAN-poort ook te vinden via de PPPoE-sessie. Nooit routes naar `0.0.0.0/0` of multicast-adressen via tv. |
| 1.0.0 | 2026-11-11 | Versie met meerdere providers. Niet gepubliceerd; vervangen door 1.1.0. |

iptv4unifi bouwt voort op **udr-iptv** 2.0.0 en 2.1.0, de KPN-voorganger van dezelfde auteur. Heb je udr-iptv geïnstalleerd, dan neemt `setup` je instellingen over.

### Bijwerken naar een nieuwe versie

```bash
curl -fsSL -o /tmp/iptv4unifi.sh https://raw.githubusercontent.com/hvklaveren/iptv4unifi/main/iptv4unifi.sh
sh /tmp/iptv4unifi.sh version                                  # nieuwe versie controleren
cp /tmp/iptv4unifi.sh /data/iptv4unifi/iptv4unifi.sh
/data/iptv4unifi/iptv4unifi.sh install                            # service opnieuw schrijven en herstarten
/data/iptv4unifi/iptv4unifi.sh version
```

Je instellingen in `iptv4unifi.conf` blijven bewaard.

## Dank

- [fabianishere/udm-iptv](https://github.com/fabianishere/udm-iptv) van Fabian Mastenbroek: de basis waarop dit is geïnspireerd.
- [unredacted/unifi-on-boot](https://github.com/unredacted/unifi-on-boot): voor het herstel na firmware-updates.

## Licentie

GPL-2.0, net als udm-iptv.
