#!/usr/bin/env python3
"""Validate translations and optionally report untranslated compiler-extracted UI keys.

Compiler extraction covers SwiftUI literals and String(localized:) calls. It does not
cover plain String labels, AppKit literals, backend messages, or the diff page; a clean
extraction report alone is not proof of complete application coverage.
"""
import argparse
import json
import plistlib
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {'zh-Hans', 'zh-Hant', 'hi', 'es', 'fr', 'bn', 'pt-BR', 'ru', 'ja', 'ko', 'sv', 'it'}
FORMAT = re.compile(r'%(?:(\d+)\$)?(lld|ld|d|f|@)')


def placeholders(text):
    """Keep each argument's type and position, allowing explicit positional reordering."""
    result = {}
    next_position = 1
    for match in FORMAT.finditer(text.replace('%%', '')):
        position = int(match[1]) if match[1] else next_position
        if position in result:
            raise ValueError(f'Duplicate format argument {position}: {text}')
        result[position] = match[2]
        if not match[1]:
            next_position += 1
    return result


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate():
    catalog = json.loads((ROOT / 'Resources/Localizable.xcstrings').read_text())
    require(catalog['sourceLanguage'] == 'en', 'English must be the source language')
    excluded = 0
    for key, entry in catalog['strings'].items():
        if entry.get('shouldTranslate') is False:
            require(not entry.get('localizations'), f'Excluded key has translations: {key}')
            require(entry.get('comment', '').strip(), f'Excluded key needs a reason: {key}')
            excluded += 1
            continue
        translations = entry.get('localizations', {})
        require(set(translations) == LANGUAGES, f'Incomplete locales: {key}')
        for language, translation in translations.items():
            unit = translation['stringUnit']
            require(unit['state'] == 'translated' and unit['value'].strip(), f'{language}: empty or unfinished {key}')
            require(placeholders(key) == placeholders(unit['value']), f'{language}: format mismatch: {key}')

    source = (ROOT / 'Scenes/Help/HelpView.swift').read_text()
    help_keys = re.findall(r'String\(localized: "([^"\n]+)"\)', source)
    require(len(help_keys) == len(set(help_keys)) == 16, 'Expected eight help titles and eight articles')
    for key in help_keys:
        require(key in catalog['strings'], f'Missing help translation: {key}')
    for command in ('gh auth login', 'acli jira auth login'):
        article = next(key for key in help_keys if command in key)
        for language, value in catalog['strings'][article]['localizations'].items():
            require(command in value['stringUnit']['value'], f'{language}: changed CLI command: {command}')
    info = json.loads((ROOT / 'Resources/InfoPlist.xcstrings').read_text())
    source_info = plistlib.loads((ROOT / 'Resources/Configs/App-Info.plist').read_bytes())
    require(info['sourceLanguage'] == 'en', 'English must be the InfoPlist source language')
    required_permissions = {key for key in source_info if key.endswith('UsageDescription')}
    # The app's name is extracted too, marked not to translate; only permission copy is translated.
    translated = {key: entry for key, entry in info['strings'].items() if entry.get('shouldTranslate', True)}
    require(set(translated) == required_permissions, 'Permission catalog must cover every usage description')
    for key, entry in translated.items():
        translations = entry['localizations']
        require(set(translations) == LANGUAGES | {'en'}, f'Incomplete permission locales: {key}')
        require(translations['en']['stringUnit']['value'] == source_info[key], f'Outdated English permission copy: {key}')
        for language, value in translations.items():
            unit = value['stringUnit']
            require(unit['state'] == 'translated' and unit['value'].strip(), f'{language}: incomplete permission copy: {key}')
    print(f"Validated {len(catalog['strings']) - excluded} entries × {len(LANGUAGES)} translations; all eight help articles and permission text covered. {excluded} nonlinguistic keys classified.")
    return catalog


def extracted_report(directory, catalog):
    files = sorted(directory.rglob('*.stringsdata'))
    require(files, f'No compiler extraction files in {directory}; build with SWIFT_EMIT_LOC_STRINGS=YES first')
    missing = {}
    extracted = set()
    for path in files:
        data = json.loads(path.read_text())
        for entry in data.get('tables', {}).get('Localizable', []):
            key = entry['key']
            extracted.add(key)
            if key not in catalog['strings']:
                reference = {'source': data['source'], 'line': entry['location']['startingLine']}
                references = missing.setdefault(key, [])
                if reference not in references:
                    references.append(reference)
    require(extracted, 'Extraction files contain no Localizable keys')
    print(f'{len(extracted)} extracted keys; {len(missing)} absent from the catalog. Includes code examples and symbols requiring classification.')
    return dict(sorted(missing.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--extracted-directory', type=Path)
    parser.add_argument('--report', type=Path, help='Write missing extracted keys and source locations as JSON')
    parser.add_argument('--strict-extracted', action='store_true', help='Fail when an extracted key is absent from the catalog')
    args = parser.parse_args()
    if (args.report or args.strict_extracted) and not args.extracted_directory:
        parser.error('--report and --strict-extracted require --extracted-directory')
    catalog = validate()
    if args.extracted_directory:
        missing = extracted_report(args.extracted_directory, catalog)
        if args.report:
            args.report.write_text(json.dumps(missing, ensure_ascii=False, indent=2) + '\n')
        if args.strict_extracted:
            require(not missing, f'{len(missing)} extracted keys still need classification or translation')


if __name__ == '__main__':
    main()
