#!/bin/bash
#Übernimmt als Parameter den Gerätenamen, z.B. 'sdb1'.

set -euo pipefail


function main() {
    initialise_defaults "$@"
    prepare_env_for_kde_or_gnome
    configure_display_and_user
    parse_cli_arguments "$@"

    if [[ "$interactive" == "true" ]]
    then
        # shellcheck disable=SC2086
        # $yesno_question must be splitted
        if ! sudo -u "$curUser" $yesno_question "Soll eine Sicherungskopie erstellt werden?"
        then
            exit
        fi
    fi

    decrypt_device
    mount_device
    create_backup "$@"
    aufraeumen

    echo_or_infobox "Eine Sicherungskopie wurde erfolgreich angelegt."
}


function initialise_defaults() {
    basedir=$(dirname "$0")
    curDate=$(date +%F_%H:%M:%S)
    interactive="true"
    keyFileName=/opt/Sicherungskopien/keyfile_extern
    mapDevice="butterbackup_${curDate}"
    mountDir=$(mktemp -d)
    start_via_udev="false"
}

function misserfolg {
    echo_or_infobox "$@"
    [[ -n "$mountDir" ]] && aufraeumen
    exit 1
}


function echo_or_infobox() {
    if [[ "$interactive" == "false" || -z "$infobox" ]]
    then
        echo "$@" >&2
    else
        # shellcheck disable=SC2086
        # $infobox must be splitted
        sudo -u "$curUser" $infobox "$@"
    fi
}


function aufraeumen {
    [[ -z "$mountDir" ]]             && return

    mount | grep -Fq "${mountDir}" && umount "${mountDir}"
    [[ -e "/dev/mapper/${mapDevice}" ]] && cryptsetup close "${mapDevice}"
    [[ -e "${mountDir}" ]]      && rmdir "${mountDir}"

    [[ -e "${mountDir}" ]]      && del_str="\nDer Ordner \"${mountDir}\" muss manuell gelöscht werden."
    [[ -e "/dev/mapper/${mapDevice}" ]] && del_str="$del_str\nDas Backupziel konnte nicht sauber entfernt werden. Die Entschlüsselung in \"/dev/mapper/${mapDevice}\" muss daher manuell gelöst werden."
    if [[ -n ${del_str:-} ]]
    then
        echo_or_infobox "$del_str"
    fi
}


function prepare_env_for_kde_or_gnome() {
    # Wir betreten die Hölle der Platformabhängigkeit.
    # Auf KDE-Systemen kann zenity nicht vorausgesetzt werden, auf
    # GNOME-Systemen hingegen kdialog nicht. Daher muss der entsprechende
    # Befehl zur Laufzeit bestimmt werden, um nicht immer zwei sehr ähnliche
    # Skripte pflegen zu müssen.
    if type kdialog > /dev/null 2> /dev/null
    then
        yesno_question="kdialog --yesno"
        pwd_prompt="kdialog --password"
        infobox="kdialog --msgbox"
    elif type zenity > /dev/null 2> /dev/null
    then
        yesno_question="zenity --question --text"
        pwd_prompt="zenity --password --text"
        infobox="zenity --info --text"
    else
        # Stilles Fehlschlagen, da wir den Fehler ja nicht anzeigen können.
        exit
    fi
}


function configure_display_and_user() {
    # Wenn das Skript via UDEV gestartet wird, ist der Nutzer root und das
    # Display nicht gesetzt. Daher müssen diese hier wild geraten werden. Bei
    # Systemen mit nur einem Benutzer sollte es aber keine Probleme geben. Wenn
    # das Skript jedoch von Hand gestartet wird, kann alles automatisch
    # bestimmt werden.
    if [[ "$start_via_udev" == true ]]
    then
        DISPLAY=:0; export DISPLAY
        curUser='#1000' #Nutzername oder NutzerID eintragen
    else
        curUser=$(who am i | awk '{print $1}') #ACHTUNG: 'who am i' kann nicht durch 'whoami' ersetzt werden!
    fi
}


function parse_cli_arguments() {
    if [[ $# -gt 3 ]]
    then
        echo "Skript mit zu vielen Argumente aufgerufen." >&2
        exit 1
    fi

    device=""
    ordnerliste=""
    while [[ $# -gt 0 ]]
    do
        local curArg
        curArg="$1"; shift
        case "$curArg" in
            -h|--help)
                echo "Hilfetext noch nicht geschrieben" >&2
                exit 1
                ;;
            -i|--interactive)
                interactive="true"
                ;;
            --no-interactive)
                interactive="false"
                ;;
            -*)
                echo "Unbekanntes Argument '$curArg'." >&2
                exit 1
                ;;
            *)
                if [[ -z "$device" ]]
                then
                    parse_device_arg "$curArg"
                elif [[ -z "$ordnerliste" ]]
                then
                    parse_ordnerliste_arg "$curArg"
                else
                    echo "Unerwartetes Argument '$curArg'." >&2
                    exit 1
                fi
        esac
    done
    if [[ -z "$device" ]]
    then
        echo "Kein Zielgerät für Backup angegeben!" >&2
        exit 1
    fi
    if [[ -z "$ordnerliste" ]]
    then
        ordnerliste="$basedir/ordnerliste"
    fi
}

function parse_device_arg() {
    deviceArg="$1"; shift
    if [[ -e "$deviceArg" ]]
    then
        device="$deviceArg"
    elif [[ -e "/dev/$deviceArg" ]]
    then
        device="/dev/$deviceArg";
    else
        misserfolg "Die Datei bzw. das Gerät, auf welche die Sicherungskopie gespielt werden soll, kann nicht gefunden werden."
    fi
}


function parse_ordnerliste_arg() {
    ordnerliste="$1"; shift
    if [[ ! -r "$ordnerliste" ]]
    then
        misserfolg "Die Liste der zu kopierenden Ordner ist nicht lesbar."
    fi
}


function decrypt_device() {
    if [[ -e $keyFileName ]]
    then
        decrypt_device_by_keyfile
    fi
    if [[ ! -e $keyFileName || $keyFileWorked -eq 2 ]]
    then
        decrypt_device_by_password
    fi
}


function decrypt_device_by_keyfile() {
    cryptsetup luksOpen "$device" "${mapDevice}" --key-file $keyFileName
    keyFileWorked=$?
    if [[ $keyFileWorked -eq 2 ]]
    then
        echo_or_infobox "Das Backupziel kann mit der Schlüsseldatei $keyFileName nicht entschlüsselt werden. Bitte geben Sie das korrekte Passwort manuell ein."
    elif [[ $keyFileWorked -ne 0 ]]
    then
        misserfolg "Das Backupziel konnte nicht entschlüsselt werden. Der Fehlercode von cryptsetup ist $keyFileWorked."
    fi
}


function decrypt_device_by_password() {
    errmsg="Die Passworteingabe wurde abgebrochen. Die Erstellung der Sicherheitskopie kann daher nicht fortgesetzt werden."
    # shellcheck disable=SC2086
    # $pwd_prompt must be splitted
    if ! pwt=$(sudo -u "$curUser" $pwd_prompt "Bitte Passwort eingeben.")
    then
        misserfolg "$errmsg"
    fi

    while ! echo "$pwt" | cryptsetup luksOpen "$device" "${mapDevice}"
    do
        # shellcheck disable=SC2086
        # $pwd_prompt must be splitted
        if ! pwt=$(sudo -u "$curUser" $pwd_prompt "Das Passwort war falsch. Bitte nochmal eingeben!")
        then
            misserfolg "$errmsg"
        fi
    done
}


function mount_device() {
    fs_type=$(file -Ls "/dev/mapper/${mapDevice}" | grep -ioE 'btrfs')
    if [[ -z "$fs_type" ]]
    then
        misserfolg "Unbekanntes Dateisystem gefunden. Unterstützt wird nur 'btrfs'."
    fi

    # Komprimierung mit ZLIB, da dies die kleinsten Dateien verspricht. Mit
    # ZSTD könnten noch höhere Komprimierungen erreicht werden, wenn ein
    # höheres Level gewählt werden könnte. Dies ist noch nicht der Fall.
    if ! mount -o compress=zlib "/dev/mapper/${mapDevice}" "${mountDir}"
    then
        misserfolg "Das Einbinden des Backupziels ist fehlgeschlagen."
    fi
}


function create_backup() {
    # Snapshot der alten Sicherungskopie duplizieren
    src_snapshot=$(find "${mountDir}" -maxdepth 1 -iname "202?-*" | sort | tail -n1)
    backup_root="${mountDir}/${curDate}"
    btrfs subvolume snapshot "${src_snapshot}" "${backup_root}"

    grep -v '^\s*#' "$ordnerliste" | while read -r line
    do
        orig=$(echo "$line" | cut -d ' ' -f1)/ # beachte abschließendes "/"!
        ziel=$(echo "$line" | cut -d ' ' -f2)
        curBackup="${backup_root}/${ziel}"
        rsync -ax --delete --inplace "$orig" "$curBackup"
    done
}

main "$@"