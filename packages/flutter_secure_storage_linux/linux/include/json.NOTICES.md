# nlohmann/json notices

`json.hpp` identifies itself as **3.11.2** in its banner and version macros.
It was inherited from the installed flutter_secure_storage_linux 3.0.3 baseline
and is not byte-identical to the upstream v3.11.2 release header. It has not been
modified by Yun's fork. Its existing copyright and SPDX notices are retained.
See [the fork provenance](../../YUN_FORK.md).

## License texts and attribution

- **JSON for Modern C++** — Copyright (c) 2013-2022 Niels Lohmann.
  [MIT license](json.LICENSE.MIT), copied from the
  [v3.11.2 LICENSE.MIT](https://github.com/nlohmann/json/blob/v3.11.2/LICENSE.MIT).
- **UTF-8 decoder** — Copyright (c) 2008-2009 Björn Hoehrmann
  <bjoern@hoehrmann.de>. MIT (full text in `json.LICENSE.MIT`).
- **Grisu2** — Copyright (c) 2009 Florian Loitsch
  <https://florian.loitsch.com/>. MIT (full text in `json.LICENSE.MIT`).
- **Hedley** — Copyright (c) 2016-2021 Evan Nemerson <evan@nemerson.com>.
  The embedded header carries an MIT SPDX identifier; upstream's v3.11.2 README
  also attributes Hedley under CC0-1.0. Both the MIT text and the complete
  [CC0-1.0 text](json.LICENSE.CC0-1.0) are supplied. The latter is copied from
  [Hedley v15 COPYING](https://github.com/nemequ/hedley/blob/v15/COPYING), matching
  the header's `JSON_HEDLEY_VERSION 15`.
- **Google Abseil portions** — Copyright (c) 2018 The Abseil Authors.
  The embedded header carries an MIT SPDX identifier and explicitly identifies
  the adapted Abseil code as Apache-2.0. Upstream's v3.11.2 README also identifies
  Abseil as Apache-2.0. The full [Apache-2.0 license](json.LICENSE.Apache-2.0) is
  copied from [v3.11.2 LICENSES/Apache-2.0.txt](https://github.com/nlohmann/json/blob/v3.11.2/LICENSES/Apache-2.0.txt).

The embedded-component descriptions and terms above follow the
[upstream v3.11.2 README license section](https://github.com/nlohmann/json/blob/v3.11.2/README.md#license)
and the notices in the vendored header. The additional texts preserve upstream
terms; they do not claim that every component is available under a choice of
licenses. Keep the header's notices together with these license texts.

These notices cover this vendored header, not all dependencies or release
binaries. The plugin's [BSD-3-Clause license](../../LICENSE) remains unchanged;
Yun's root MIT license does not replace these third-party licenses.
