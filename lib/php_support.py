"""PHP versions simai-env marks outdated (they get no security fixes) and the
oldest it runs. The one list lives in admin/lib/php_utils.sh
(SIMAI_PHP_OUTDATED, SIMAI_PHP_MIN_SUPPORTED); this module reads it from
there for the JSON answers (php list, self describe, site describe,
self profiles).
"""
import re
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "admin" / "lib" / "php_utils.sh"


def _read():
    try:
        text = SOURCE.read_text()
    except OSError:
        return [], None
    m = re.search(r'^SIMAI_PHP_OUTDATED="([0-9. ]*)"$', text, re.M)
    low = re.search(r'^SIMAI_PHP_MIN_SUPPORTED="([0-9.]+)"$', text, re.M)
    return (m.group(1).split() if m else []), (low.group(1) if low else None)


OUTDATED, MIN_SUPPORTED = _read()


def outdated(version):
    return version in OUTDATED


def key(version):
    return tuple(int(x) for x in version.split("."))


def supported(version):
    return not MIN_SUPPORTED or key(version) >= key(MIN_SUPPORTED)
