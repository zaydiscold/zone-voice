# Third-party notices

Zone is released under the MIT License. It ships, or is built from, the following third-party material.

## English word list (keyboard autocorrect)

`ZoneCore/Sources/ZoneCore/Resources/en-words.txt` is generated from two sources, neither checked in:

1. **SCOWL (Spell Checker Oriented Word Lists) 2020.12.07, sizes 10 to 60**, by Kevin Atkinson, http://wordlist.aspell.net/. It decides which words are valid and how they are cased. Its copyright notice, reproduced in full below as it requires, permits use, modification, distribution and sale with the notice kept. Zone uses only sizes 10 to 60, so the UKACD terms (size 80) do not apply, but the whole notice is kept for simplicity.
2. **Wikipedia word frequency list, enwiki-2023-04-13**, by Ilya Semenov, https://github.com/IlyaSemenov/wikipedia-word-frequency, MIT License (below). Zone uses only the counts, to rank words; no Wikipedia text is shipped.

## iroh (Zone Link)

The Zone app links `Iroh.xcframework` and the generated Swift binding `IrohLib.swift` from
**iroh-ffi 1.2.0**, copyright N0, INC., https://github.com/n0-computer/iroh-ffi, licensed MIT OR Apache-2.0.
Neither is checked in: `scripts/build-iroh.sh` compiles the library from that release's source at a pinned
revision, with two changes so it imports only public iOS API: netdev (MIT, https://github.com/shellrow/netdev)
at the merge commit of its pull request 195, and `scripts/iroh-patches/` applied to n0-dns-resolver 0.1.0
(MIT OR Apache-2.0). The Swift binding it generates is byte for byte the release's.
The library is built from iroh and the Rust crates it depends on, each under its own license (mostly MIT,
Apache-2.0, BSD and ISC); their notices are in the iroh-ffi repository's `Cargo.lock` and crate sources.
Only the Zone app contains this code. The keyboard and the other extensions do not.

## Swipe word pairs (keyboard)

`ZoneKeyboard/Resources/en-pairs.bin` holds pruned, quantized next-word probabilities counted from the English OpenSubtitles2018 corpus as distributed by OPUS (https://opus.nlpl.eu/), built by `scripts/swipe-eval/build-wordpairs.py`. No subtitle text is shipped. OPUS asks users to cite P. Lison and J. Tiedemann, "OpenSubtitles2016: Extracting Large Parallel Corpora from Movie and TV Subtitles", LREC 2016, and the source site http://www.opensubtitles.org/; the in-app acknowledgments do.

Short lists of texting words and of words that are valid but never suggested were written for Zone and are covered by Zone's own MIT License.

### SCOWL copyright notice (verbatim from `scowl-2020.12.07/Copyright`)

```
The collective work is Copyright 2000-2018 by Kevin Atkinson as well
as any of the copyrights mentioned below:

  Copyright 2000-2018 by Kevin Atkinson

  Permission to use, copy, modify, distribute and sell these word
  lists, the associated scripts, the output created from the scripts,
  and its documentation for any purpose is hereby granted without fee,
  provided that the above copyright notice appears in all copies and
  that both that copyright notice and this permission notice appear in
  supporting documentation. Kevin Atkinson makes no representations
  about the suitability of this array for any purpose. It is provided
  "as is" without express or implied warranty.

Alan Beale <biljir@pobox.com> also deserves special credit as he has,
in addition to providing the 12Dicts package and being a major
contributor to the ENABLE word list, given me an incredible amount of
feedback and created a number of special lists (those found in the
Supplement) in order to help improve the overall quality of SCOWL.

The 10 level includes the 1000 most common English words (according to
the Moby (TM) Words II [MWords] package), a subset of the 1000 most
common words on the Internet (again, according to Moby Words II), and
frequently class 16 from Brian Kelk's "UK English Wordlist
with Frequency Classification".

The MWords package was explicitly placed in the public domain:

    The Moby lexicon project is complete and has
    been place into the public domain. Use, sell,
    rework, excerpt and use in any way on any platform.

    Placing this material on internal or public servers is
    also encouraged. The compiler is not aware of any
    export restrictions so freely distribute world-wide.

    You can verify the public domain status by contacting

    Grady Ward
    3449 Martha Ct.
    Arcata, CA  95521-4884

    grady@netcom.com
    grady@northcoast.com

The "UK English Wordlist With Frequency Classification" is also in the
Public Domain:

  Date: Sat, 08 Jul 2000 20:27:21 +0100
  From: Brian Kelk <Brian.Kelk@cl.cam.ac.uk>

  > I was wondering what the copyright status of your "UK English
  > Wordlist With Frequency Classification" word list as it seems to
  > be lacking any copyright notice.

  There were many many sources in total, but any text marked
  "copyright" was avoided. Locally-written documentation was one
  source. An earlier version of the list resided in a filespace called
  PUBLIC on the University mainframe, because it was considered public
  domain.

  Date: Tue, 11 Jul 2000 19:31:34 +0100

  > So are you saying your word list is also in the public domain?

  That is the intention.

The 20 level includes frequency classes 7-15 from Brian's word list.

The 35 level includes frequency classes 2-6 and words appearing in at
least 11 of 12 dictionaries as indicated in the 12Dicts package.  All
words from the 12Dicts package have had likely inflections added via
my inflection database.

The 12Dicts package and Supplement is in the Public Domain.

The WordNet database, which was used in the creation of the
Inflections database, is under the following copyright:

  This software and database is being provided to you, the LICENSEE,
  by Princeton University under the following license.  By obtaining,
  using and/or copying this software and database, you agree that you
  have read, understood, and will comply with these terms and
  conditions.:

  Permission to use, copy, modify and distribute this software and
  database and its documentation for any purpose and without fee or
  royalty is hereby granted, provided that you agree to comply with
  the following copyright notice and statements, including the
  disclaimer, and that the same appear on ALL copies of the software,
  database and documentation, including modifications that you make
  for internal use or for distribution.

  WordNet 1.6 Copyright 1997 by Princeton University.  All rights
  reserved.

  THIS SOFTWARE AND DATABASE IS PROVIDED "AS IS" AND PRINCETON
  UNIVERSITY MAKES NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR
  IMPLIED.  BY WAY OF EXAMPLE, BUT NOT LIMITATION, PRINCETON
  UNIVERSITY MAKES NO REPRESENTATIONS OR WARRANTIES OF MERCHANT-
  ABILITY OR FITNESS FOR ANY PARTICULAR PURPOSE OR THAT THE USE OF THE
  LICENSED SOFTWARE, DATABASE OR DOCUMENTATION WILL NOT INFRINGE ANY
  THIRD PARTY PATENTS, COPYRIGHTS, TRADEMARKS OR OTHER RIGHTS.

  The name of Princeton University or Princeton may not be used in
  advertising or publicity pertaining to distribution of the software
  and/or database.  Title to copyright in this software, database and
  any associated documentation shall at all times remain with
  Princeton University and LICENSEE agrees to preserve same.

The 40 level includes words from Alan's 3esl list found in version 4.0
of his 12dicts package.  Like his other stuff the 3esl list is also in the
public domain.

The 50 level includes Brian's frequency class 1, words appearing
in at least 5 of 12 of the dictionaries as indicated in the 12Dicts
package, and uppercase words in at least 4 of the previous 12
dictionaries.  A decent number of proper names is also included: The
top 1000 male, female, and Last names from the 1990 Census report; a
list of names sent to me by Alan Beale; and a few names that I added
myself.  Finally a small list of abbreviations not commonly found in
other word lists is included.

The name files form the Census report is a government document which I
don't think can be copyrighted.

The file special-jargon.50 uses common.lst and word.lst from the
"Unofficial Jargon File Word Lists" which is derived from "The Jargon
File".  All of which is in the Public Domain.  This file also contain
a few extra UNIX terms which are found in the file "unix-terms" in the
special/ directory.

The 55 level includes words from Alan's 2of4brif list found in version
4.0 of his 12dicts package.  Like his other stuff the 2of4brif is also
in the public domain.

The 60 level includes all words appearing in at least 2 of the 12
dictionaries as indicated by the 12Dicts package.

The 70 level includes Brian's frequency class 0 and the 74,550 common
dictionary words from the MWords package.  The common dictionary words,
like those from the 12Dicts package, have had all likely inflections
added.  The 70 level also included the 5desk list from version 4.0 of
the 12Dics package which is in the public domain.

The 80 level includes the ENABLE word list, all the lists in the
ENABLE supplement package (except for ABLE), the "UK Advanced Cryptics
Dictionary" (UKACD), the list of signature words from the YAWL package,
and the 10,196 places list from the MWords package.

The ENABLE package, mainted by M\Cooper <thegrendel@theriver.com>,
is in the Public Domain:

  The ENABLE master word list, WORD.LST, is herewith formally released
  into the Public Domain. Anyone is free to use it or distribute it in
  any manner they see fit. No fee or registration is required for its
  use nor are "contributions" solicited (if you feel you absolutely
  must contribute something for your own peace of mind, the authors of
  the ENABLE list ask that you make a donation on their behalf to your
  favorite charity). This word list is our gift to the Scrabble
  community, as an alternate to "official" word lists. Game designers
  may feel free to incorporate the WORD.LST into their games. Please
  mention the source and credit us as originators of the list. Note
  that if you, as a game designer, use the WORD.LST in your product,
  you may still copyright and protect your product, but you may *not*
  legally copyright or in any way restrict redistribution of the
  WORD.LST portion of your product. This *may* under law restrict your
  rights to restrict your users' rights, but that is only fair.

UKACD, by J Ross Beresford <ross@bryson.demon.co.uk>, is under the
following copyright:

  Copyright (c) J Ross Beresford 1993-1999. All Rights Reserved.

  The following restriction is placed on the use of this publication:
  if The UK Advanced Cryptics Dictionary is used in a software package
  or redistributed in any form, the copyright notice must be
  prominently displayed and the text of this document must be included
  verbatim.

  There are no other restrictions: I would like to see the list
  distributed as widely as possible.

The 95 level includes the 354,984 single words, 256,772 compound
words, 4,946 female names and the 3,897 male names, and 21,986 names
from the MWords package, ABLE.LST from the ENABLE Supplement, and some
additional words found in my part-of-speech database that were not
found anywhere else.

Accent information was taken from UKACD.

The VarCon package was used to create the American, British, Canadian,
and Australian word list.  It is under the following copyright:

  Copyright 2000-2016 by Kevin Atkinson

  Permission to use, copy, modify, distribute and sell this array, the
  associated software, and its documentation for any purpose is hereby
  granted without fee, provided that the above copyright notice appears
  in all copies and that both that copyright notice and this permission
  notice appear in supporting documentation. Kevin Atkinson makes no
  representations about the suitability of this array for any
  purpose. It is provided "as is" without express or implied warranty.

  Copyright 2016 by Benjamin Titze

  Permission to use, copy, modify, distribute and sell this array, the
  associated software, and its documentation for any purpose is hereby
  granted without fee, provided that the above copyright notice appears
  in all copies and that both that copyright notice and this permission
  notice appear in supporting documentation. Benjamin Titze makes no
  representations about the suitability of this array for any
  purpose. It is provided "as is" without express or implied warranty.

  Since the original words lists come from the Ispell distribution:

  Copyright 1993, Geoff Kuenning, Granada Hills, CA
  All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:

  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.
  3. All modifications to the source code must be clearly marked as
     such.  Binary redistributions based on modified source code
     must be clearly marked as modified versions in the documentation
     and/or other materials provided with the distribution.
  (clause 4 removed with permission from Geoff Kuenning)
  5. The name of Geoff Kuenning may not be used to endorse or promote
     products derived from this software without specific prior
     written permission.

  THIS SOFTWARE IS PROVIDED BY GEOFF KUENNING AND CONTRIBUTORS ``AS IS'' AND
  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
  ARE DISCLAIMED.  IN NO EVENT SHALL GEOFF KUENNING OR CONTRIBUTORS BE LIABLE
  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
  SUCH DAMAGE.
```

### Wikipedia word frequency list license

```
MIT License

Copyright (c) 2015 Ilya Semenov

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
```

## Speech recognition libraries and models

- **FluidAudio** (FluidInference/FluidAudio), Apache License 2.0, built from Zone's fork (zaydiscold/FluidAudio, branch `zone/main`): upstream's main branch after 0.18.3 with Zone's decoder changes, which are also offered upstream. Linked into the app for the optional Core ML engines.
- **Fluid Speech Mini** (FluidVoice Labs, built on NVIDIA Parakeet TDT 0.6B v3), Zone's speech model, downloaded from Hugging Face the first time it is needed, CC BY 4.0. Settings, Speech model names it and its license. **Parakeet TDT-CTC 110M** (NVIDIA, CC BY 4.0) is retired and no longer offered. Zone changes Fluid Speech Mini's joint network after download: it adds a top-K output to the same Core ML program, reading the downloaded weights unchanged (`Packages/ZoneFluidAudio/Sources/ZoneFluidAudio/FluidMiniJointTopK`, built by `scripts/spelled-letter-eval/build_mini_joint_topk_shared.py`).
- Apple's SpeechTranscriber and DictationTranscriber are part of iOS.
- **Speaker diarization models** for Meetings (FluidInference/speaker-diarization-coreml, the revision pinned by FluidAudio, unchanged since 0.18.3: Segmentation, FBank, Embedding, PldaRho and plda-parameters.json, about 21.6 MB), downloaded from Hugging Face only when a meeting is first labeled, CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Modified Core ML conversions by Fluid Inference of the pyannote community-1 segmentation model (pyannote), the WeSpeaker speaker embedding (WeSpeaker) and VBx PLDA parameters (BUT Speech@FIT). VBx clustering code in FluidAudio is Apache License 2.0.

## Dictation sounds

`Zone/Resources/Sounds/dictation-start.caf` and `dictation-stop.caf` are synthesized from sine partials by `scripts/make-sounds.py`. They contain no third-party audio and are covered by Zone's MIT License.

## US Social Security Administration baby names

`ZoneCore/Sources/ZoneCore/Resources/first-names.txt` is derived from the Social Security
Administration's national baby name data (https://www.ssa.gov/oact/babynames/limits.html), a
public domain work of the US government.

## Swipe recognition

Powered by FUTO Swipe. Recognition uses the FUTO Swipe Model. The bundled `futoswipe.bin` encoder weights use the **FUTO Model
Weights License 1.0**. They were converted to fp16 by VietTelex and were not retrained by
Zone. SHA-256: `59e41b223f2bbb846429ff60b4c7d98c30ba86cadb9aecbc4ac82e0e5443f089`.

The Swift/Accelerate inference implementation and Python parity fixture come from
[ptrinh/viettelex](https://github.com/ptrinh/viettelex), revision
`d9c6f20d4bf4dec4feffafa74730114a25801d9d`, copyright 2026 Phil Trinh, MIT.
Full MIT and model terms, including the derivative notice, are reproduced in
[SwipeNotices.txt](ZoneCore/Sources/ZoneCore/Resources/SwipeNotices.txt), bundled in the app
and accessible from Keyboard settings. FUTO's GPL swipe-library runtime is not included.

The external evaluation corpus is [futo-org/swipe.futo.org](https://huggingface.co/datasets/futo-org/swipe.futo.org)
(MIT). Raw corpus traces are not distributed with Zone.

## Scope voice graphic (Hex)

`Shared/Hex/DotScope.swift` and `Shared/Hex/DotScopeShaderSource.swift` are the braided dot
oscilloscope from **Hex**, https://github.com/anomalyco/hex (`ios/HEXShared/DotScope.swift` and
`DotScopeShader.metal` at commit 9787c49), Copyright (c) 2026 Christopher Langton, MIT License.
Zone changed one thing: the shader is compiled from source on the device. The MIT permission
notice reproduced above applies to it word for word, with that copyright line.
