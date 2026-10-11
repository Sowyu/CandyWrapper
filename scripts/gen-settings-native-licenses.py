"""Package the notices for the native client's shipped code and artwork."""
import json
from pathlib import Path
root = Path(__file__).resolve().parent.parent
entries = []
for name, version, license, source, path in [
    ('T3 Code', None, 'MIT', 'https://github.com/pingdotgg/t3code', 'docs/research/settings-sweep/LICENSE-t3.txt'),
    ('SwiftTerm', '1.19.0', 'MIT', 'https://github.com/migueldeicaza/SwiftTerm', 'Packages/SwiftTerm/LICENSE'),
    ('Lucide', None, 'ISC', 'https://lucide.dev', 'Packages/CandyKit/Sources/DesignSystem/Icons/LICENSE-lucide.txt'),
    ('Mermaid', None, 'MIT', 'https://github.com/mermaid-js/mermaid', 'Packages/CandyKit/Sources/Features/Resources/LICENSE-mermaid.txt'),
]:
    entries.append(dict(bundles=['CandyWrapper'], kind='package', license=license, name=name,
                        noticeText=(root/path).read_text(), sourceUrl=source, version=version))
entries.append(dict(bundles=['CandyWrapper'], kind='custom', license='Pixabay Content License',
                    name='Candy Town by Aya_Lu', noticeText='Candy Town by Aya_Lu. Used under the Pixabay Content License. The native client uses a cropped, duotone version of the artwork.',
                    sourceUrl='https://pixabay.com/illustrations/candy-town-city-buildings-8579300/', version=None))
(root/'Packages/CandyKit/Sources/Features/Resources/native-licenses.json').write_text(json.dumps(dict(schemaVersion=1, entries=entries), indent=2)+'\n')
