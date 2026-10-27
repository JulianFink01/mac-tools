# Hinweise auf Drittanbieter

## Fensterbezogene Hintergrund-Eingaben

Frühere lokale Versuche mit macOS-Fokus- und Eingabe-Schnittstellen folgten dem von [Cua](https://github.com/trycua/cua)
und [yabai](https://github.com/koekeishiya/yabai) dokumentierten Prinzip:
MacTools verwendet in der ausgelieferten Fensteransicht native Eingaben auf einer virtuellen Fläche und enthält keinen Cua-Treiber und keinen yabai-Dienst.

### Cua

MIT License

Copyright (c) 2025 Cua AI, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### yabai

The MIT License (MIT)

Copyright (c) 2019 Åsmund Vikane

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## ClamAV

Die gebündelte ClamAV-Laufzeit enthält ihre Lizenzen und Herkunftsnachweise
unter `Contents/Resources/ClamAV`. Die Quellcode- und Versionsangaben stehen
auch in [Vendor/README.md](Vendor/README.md). ClamAV steht unter GPLv2.

## Virtuelle Fensterfläche

Die CoreGraphics-Laufzeitschnittstellen in `MacTools/VirtualWindowDisplay.m`
und die HiDPI-Konfiguration orientieren sich an der dokumentierten Implementierung
von [Chromium](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm).

// Copyright 2015 The Chromium Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google LLC nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Mermaid 11.12.0 · MIT · https://github.com/mermaid-js/mermaid · license: Vendor/Mermaid/LICENSE

xterm.js 6.0.0 and addon-fit 0.11.0 · MIT · https://github.com/xtermjs/xterm.js · licenses: Vendor/Terminal/LICENSE-xterm, Vendor/Terminal/LICENSE-addon-fit

Chat rendering libraries (bundled under Contents/Resources/ChatRenderer; full license texts in LICENSE-*):

- KaTeX 0.19.1 (including fonts) · MIT · https://github.com/KaTeX/KaTeX
- Marked 18.1.2 · MIT · https://github.com/markedjs/marked
- DOMPurify 3.4.17 · MPL-2.0 OR Apache-2.0 · https://github.com/cure53/DOMPurify
- Plotly.js 4.1.2 · MIT · https://github.com/plotly/plotly.js
- Vega 6.4.0, Vega-Lite 6.5.0, Vega Embed 7.3.0 · BSD-3-Clause · https://github.com/vega
