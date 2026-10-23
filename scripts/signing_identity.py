"""Preserve macOS permission identities; never edit TCC or reset permissions."""
import subprocess

COMPONENTS = (('', 'local.pico'), ('Contents/Helpers/OpenToolkit Speech.app', 'local.pico.speech'))


def identity(path):
    result = subprocess.run(['codesign', '-d', '-r-', '--verbose=2', str(path)], capture_output=True, text=True)
    if result.returncode:
        raise ValueError('Cannot inspect the app signature: ' + str(path.name))
    lines = (result.stdout + '\n' + result.stderr).splitlines()
    def field(prefix):
        return next((line[len(prefix):] for line in lines if line.startswith(prefix)), '')
    return {'identifier': field('Identifier='), 'team': field('TeamIdentifier='),
            'requirement': field('designated => '),
            'developer_id': any(line.startswith('Authority=Developer ID Application:') for line in lines)}


def validate_upgrade(previous, candidate):
    """A source install must not silently replace a signed release with ad-hoc code."""
    if not previous.exists():
        return
    for relative, expected in COMPONENTS:
        old = identity(previous / relative)
        if old['team'] in ('', 'not set'):
            continue
        new = identity(candidate / relative)
        if (old['identifier'] != expected or new['identifier'] != expected or
                old['team'] != new['team'] or not old['requirement'] or
                old['requirement'] != new['requirement']):
            raise ValueError('This update changes the installed signing identity and could reset permissions. '
                             'Use the signed release, or build with the same Developer ID via OPENTOOLKIT_SIGNING_IDENTITY. '
                             'Your installed app and data have not been replaced.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(candidate)], check=True)


def validate_release(app):
    result = {}
    for relative, expected in COMPONENTS:
        component = identity(app / relative)
        if component['identifier'] != expected or not component['developer_id'] or not component['requirement']:
            raise ValueError('Release must retain the app/helper IDs and use Developer ID Application signing.')
        result[expected] = component
    if len({item['team'] for item in result.values()}) != 1:
        raise ValueError('App and speech helper must be signed by the same team.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return result
