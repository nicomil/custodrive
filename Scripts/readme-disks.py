#!/usr/bin/env python3
"""Builds the disposable NTFS disk images shown in the README screenshots.

Usage: readme-disks.py WORK_DIR MKNTFS ENGINE_TEST_BINARY LANGUAGE

Writes WORK_DIR/LANGUAGE-archive.img and LANGUAGE-backup.img (raw MBR disks
with one NTFS partition, sparse), the source files they were filled from,
and WORK_DIR/LANGUAGE-plan.json for the in-app tour (ReadmeShots.swift).
Folder and file names are localized so each README shows its own language.
"""
import json
import os
import random
import struct
import subprocess
import sys

TEXT = {
    'en': dict(archive='Photo Archive', backup='Backup Drive',
               folders=['Holidays 2026', 'Portraits', 'Videos', 'Work'],
               readme=('ReadMe.txt', 'Photos from 2026.\n'),
               photos=['Sunset beach', 'Mountain lake', 'City at night', 'Lavender fields',
                       'Autumn forest', 'Open sea'],
               backup_folders=['Documents', 'Music'], video='Trip to the mountains.mov'),
    'it': dict(archive='Archivio Foto', backup='Disco Backup',
               folders=['Vacanze 2026', 'Ritratti', 'Video', 'Lavoro'],
               readme=('Leggimi.txt', 'Foto del 2026.\n'),
               photos=['Spiaggia al tramonto', 'Lago di montagna', 'Città di notte',
                       'Campi di lavanda', "Bosco d'autunno", 'Mare aperto'],
               backup_folders=['Documenti', 'Musica'], video='Gita in montagna.mov'),
    'es': dict(archive='Archivo Fotos', backup='Disco Copia',
               folders=['Vacaciones 2026', 'Retratos', 'Vídeos', 'Trabajo'],
               readme=('Léeme.txt', 'Fotos de 2026.\n'),
               photos=['Playa al atardecer', 'Lago de montaña', 'Ciudad de noche',
                       'Campos de lavanda', 'Bosque de otoño', 'Mar abierto'],
               backup_folders=['Documentos', 'Música'], video='Excursión a la montaña.mov'),
}
MiB = 1024 * 1024


def disk(path, label, size, records, mkntfs, engine):
    """mkntfs on a partition file, filled by the Custodrive engine, then
    wrapped in an MBR so macOS attaches it like an external disk."""
    part = path + '.part'
    with open(part, 'wb') as f:
        f.truncate(size - MiB)
    os.chmod(part, 0o600)
    subprocess.run([mkntfs, '-F', '-Q', '-p', '2048', '-H', '255', '-S', '63', '-L', label, part],
                   check=True, capture_output=True)
    if records:
        manifest = path + '.manifest'
        with open(manifest, 'wb') as f:
            f.write(b''.join(str(field).encode() + b'\0' for record in records for field in record))
        result = subprocess.run([engine, '--image', part, '--manifest', manifest], capture_output=True)
        if result.returncode:
            sys.exit(result.stderr.decode())
    mbr = bytearray(512)
    mbr[440:444] = random.randbytes(4)
    mbr[446:462] = bytes([0, 0xfe, 0xff, 0xff, 0x07, 0xfe, 0xff, 0xff]) + \
        struct.pack('<II', 2048, (size - MiB) // 512)
    mbr[510:512] = b'\x55\xaa'
    with open(path, 'wb') as out, open(part, 'rb') as src:
        out.truncate(size)
        out.write(mbr)
        out.seek(MiB)
        while chunk := src.read(4 * MiB):
            if chunk.count(0) == len(chunk):
                out.seek(len(chunk), 1)
            else:
                out.write(chunk)
    os.remove(part)


def main():
    work, mkntfs, engine, language = sys.argv[1:]
    text = TEXT[language]
    random.seed(2026)
    source = os.path.join(work, 'src-' + language)
    os.makedirs(source, exist_ok=True)

    def blob(name, size):
        path = os.path.join(source, name)
        with open(path, 'wb') as f:
            f.write(random.randbytes(size))
        return path

    holiday, portraits, videos, work_folder = text['folders']
    records = [('D', folder) for folder in sorted(text['folders'])]
    readme, content = text['readme']
    with open(os.path.join(source, readme), 'w', encoding='utf-8') as f:
        f.write(content)
    records.append(('F', os.path.join(source, readme), '', readme, '0'))
    for i, photo in enumerate(text['photos']):
        name = f'IMG_{2100 + i} - {photo}.jpg'
        records.append(('F', blob(name, random.randint(70, 92) * 1024), holiday, name, '0'))
    for i in range(1, 5):
        name = f'IMG_{3000 + i}.jpg'
        records.append(('F', blob(name, random.randint(80, 120) * 1024), portraits, name, '0'))
    disk(os.path.join(work, language + '-archive.img'), text['archive'], 2 * 1024 * MiB,
         records, mkntfs, engine)
    disk(os.path.join(work, language + '-backup.img'), text['backup'], 1024 * MiB,
         [('D', folder) for folder in text['backup_folders']], mkntfs, engine)

    video = os.path.join(source, text['video'])
    with open(video, 'wb') as f:  # large enough to catch the progress bar
        for _ in range(30):
            f.write(random.randbytes(32 * MiB))
    plan = dict(archive=text['archive'], holiday=holiday, portraits=portraits, videos=videos,
                work=work_folder, video=video, output=os.path.join(work, 'shots-' + language))
    os.makedirs(plan['output'], exist_ok=True)
    with open(os.path.join(work, language + '-plan.json'), 'w', encoding='utf-8') as f:
        json.dump(plan, f, ensure_ascii=False)


if __name__ == '__main__':
    main()
