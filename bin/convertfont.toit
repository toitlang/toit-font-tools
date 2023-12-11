// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// Converts a bitmap font in BDF format to an include-able Toit font.

import crypto.sha256 show *
import host.file
import reader show BufferedReader
import cli

verbose/bool := false

main args:
  root-cmd := cli.Command "convert"
    --long-help="Convert a BDF font to a Toit font."
    --options=[
        cli.Flag "bold"
            --short-name="b"
            --short-help="Make the font bold by smearing the pixels horizontally.",
        cli.Flag "verbose"
            --short-name="v"
            --short-help="Produce a more verbose .toit file.",
        cli.Flag "doc-comments"
            --short-name="d"
            --short-help="Use /** */ comments instead of // comments.",
        cli.Option "copyright-file"
            --short-name="c"
            --short-help="File containing the copyright notice."
            --type="file",
        ]
    --rest=[
        cli.Option "bdf-file-in"
            --short-help="The BDF file to read."
            --type="file"
            --required,
        cli.Option "font-name"
            --short-help="The name of the font."
            --required,
        cli.Option "toit-file-out"
            --short-help="The .toit file to write."
            --type="file"
            --required,
        ]
    --run= :: convert it
  root-cmd.run args

convert parsed/cli.Parsed:
  bold := parsed["bold"]
  verbose = parsed["verbose"]
  copyright-file := parsed["copyright_file"]
  bdf-file := parsed["bdf-file-in"]
  font-name := parsed["font-name"]
  toit-file := parsed["toit-file-out"]
  font-reader := FontReader bdf-file font-name --bold=bold --doc-comments=parsed["doc-comments"]
  font-reader.parse
  font-reader.dump toit-file copyright-file

COMPRESSING ::= true

class Char:
  // The horizontal space the glyph takes up on a line of text.  Not to be
  // confused with the width of the bounding box, which is normally a little
  // less, to allow for inter-glyph spacing.
  width := 0
  // Bounding box.  Describes both the size of the glyph bitmap, and also the
  // offset relative to the text baseline and the surrounding characters.
  bbox/BBox ::= ?
  // Bytes describing the bitmap of the glyph.  Eg. for a glyph that is between
  // 17 and 24 pixels wide we use three bytes per line.
  //   byte1 byte2 byte3
  //   byte4 byte5 byte6
  // Within each byte the most significant bit is on the left and the least
  // significant bit is on the right.
  bits / ByteArray  := ?
  name / string

  constructor .width/int .bbox/BBox .bits .name:

  bytes-per-line_ -> int:
    return (bbox.width + 7) >> 3

  make-bold:
    bytes-per-line := bytes-per-line_
    // Smear out the pixels for artificial bold mode.
    if bbox.width & 7 != 0:
      smear_ bits bits 0 0 bits.size
    else:
      new-bytes-per-line := bytes-per-line + 1
      new-bits := ByteArray new-bytes-per-line * bbox.height
      bbox.height.repeat: | y |
        smear_
          bits
          new-bits
          y * bytes-per-line
          y * new-bytes-per-line
          bytes-per-line
      bits = new-bits
    width++
    bbox.width++

  smear_ in/ByteArray out/ByteArray in-from/int out-from/int count/int:
    carry := false
    count.repeat:
      t := in[in-from + it]
      new-carry := (t & 1) != 0
      t |= t >> 1
      if carry: t |= 0x80
      out[out-from + it] = t
      carry = new-carry
    if carry:
      // If this triggers a bounds check then that means the font
      // has bits that are black outside the bbox of the character,
      // which is a bug in the font.
      out[out-from + count] |= 0x80

class UnicodeBlock:
  name/string ::= ?
  from/int ::= ?
  to/int ::= ?
  assigned/int ::= ?
  wikipedia-name_/string ::= ?
  right-to-left/bool ::= ?
  vertical/bool ::= ?
  abugida/bool ::= ?  // Syllable-based using diacritics for vowels.
  combining/bool ::= ?  // Accents that combine with other characters.
  contains-icons/bool ::= ?

  wikipedia-name -> string:
    return wikipedia-name_

  constructor .name/string .from/int .to/int --.assigned=(to + 1 - from) --disambiguate=(not name.contains " ") --wikipedia-name="" --.right-to-left=false --.vertical=false --.abugida=false --.combining=false --.contains-icons=false:
    if wikipedia-name == "":
      bytes := ByteArray name.size:
        c := name[it]
        c == ' ' ? '_' : c
      autogen-name := bytes.to-string
      if disambiguate:
        wikipedia-name_ = "$(autogen-name)_%28Unicode_block%29"
      else:
        wikipedia-name_ = autogen-name
    else:
      wikipedia-name_ = wikipedia-name

class Block:
  unicode-block := ?
  used := false
  chars := []

  name: return unicode-block.name
  from: return unicode-block.from
  to: return unicode-block.to

  constructor .unicode-block/UnicodeBlock:
    chars = List
      to + 1 - from
      null

  set i/int c/Char -> none:
    used = true
    chars[i - from] = c

  make-bold:
    do: | c | c.make-bold

  do [block]:
    (to + 1 - from).repeat: | j |
      c := chars[j]
      if c: block.call c from + j

  all-caps-identifier -> string:
    byte-count := 0
    name-bytes := ByteArray name.size
    for i := 0; i < name.size; i++:
      byte := name.at --raw i
      if 'a' <= byte <= 'z':
        name-bytes[byte-count++] = byte - 'a' + 'A'
      else if 'A' <= byte <= 'Z' or '0' <= byte <= '9':
        name-bytes[byte-count++] = byte
      else if byte == ' ' or byte == '-' or byte == '_':
        if i == name.size - 1:
          name-bytes[byte-count++] = '_'
        else:
          name-bytes[byte-count++] = '-'
    return name-bytes.to-string 0 byte-count

class BBox:
  width := 0
  height := 0
  xoffset := 0
  yoffset := 0

  constructor s/string:
    parts := s.split " "

    width = int.parse parts[0]
    height = int.parse parts[1]
    xoffset = int.parse parts[2]
    yoffset = int.parse parts[3]

class FontReader:
  filename/string ::= ?
  font-name/string ::= ?
  bold/bool ::= ?
  doc-comments/bool ::= ?

  blocks := ?

  static ICON-BLOCK-SIZE ::= 8

  constructor .filename/string .font-name/string --.bold=false --.doc-comments=false:
    blocks = UNICODE-BLOCKS.map: Block it
    List.chunk-up 0xF_0000 0x11_0000 ICON-BLOCK-SIZE: | from to |
      blocks.add
        Block
          UnicodeBlock
            "Icon range $(%x from)-$(%x to - 1)_"
            from
            to - 1
            --wikipedia-name="Material_Design"
            --contains-icons
    clear

  clear -> none:
    bits = []
    char-name = ""
    state = NOTHING
    encoding = null
    bbox = null
    width = null

  static NOTHING ::= 0
  static IN-CHAR ::= 1
  static IN-BITMAP ::= 2
  static IGNORE-CHAR ::= 3

  state := NOTHING
  encoding := null
  bits := []
  char-name := ""
  copyright := ""
  copyright-lines := []
  comment-lines := []
  bbox := null
  width := null

  parse -> none:
    fd := file.Stream.for-read filename
    reader := BufferedReader fd

    current-block := null
    block-index := 0

    old-state := ""
    old-line := ""

    while line := reader.read-line:
      old-state = state
      old-line = line
      if state == NOTHING:
        if line.starts-with "COPYRIGHT":
          c := line.size == 9 ? "" : (line.copy 10)
          copyright-lines.add c
          if line.starts-with "\"" and c.ends-with "\"":
            c = c.copy 1 (c.size - 1)
          if copyright == "":
            copyright = c
          else:
            if c == "":
              copyright = "$copyright\n"
            else:
              if copyright.ends-with "\n":
                copyright = "$copyright$c"
              else:
                copyright = "$copyright $c"
        else if line.starts-with "COMMENT":
          c := line.size == 7 ? "" : (line.copy 8)
          comment-lines.add c
        else if line.starts-with "STARTCHAR":
          state = IN-CHAR
          char-name = line.copy 10
        else if line.starts-with "ENDFONT":
          fd.close
          return
      else if state == IN-CHAR:
        if line.starts-with "ENCODING":
          encoding = int.parse (line.copy 9)
          if encoding < 32:
            state = IGNORE-CHAR
        else if line.starts-with "BITMAP":
          assert: encoding != null
          state = IN-BITMAP
        else if line.starts-with "BBX":
          bbox = BBox (line.copy 4)
        else if line.starts-with "DWIDTH":
          width = int.parse
            line.copy 7 (line.index-of " " 7)
      else if state == IN-BITMAP:
        if line.starts-with "ENDCHAR":
          bytes := ByteArray bits.size: bits[it]
          c := Char width bbox bytes char-name
          while current-block == null or current-block.to < encoding:
            current-block = blocks[block-index++]
          current-block.set encoding c
          clear
        else:
          while line.size >= 2:
            hex := line.copy 0 2
            line = line.copy 2
            b := int.parse hex --radix=16
            bits.add b
      else if state == IGNORE-CHAR and line.starts-with "ENDCHAR":
        state = NOTHING

  dump-copyright-file copyright-file/string fd -> none:
    license-text := file.read-content copyright-file
    license-text.to-string.split "\n":
      line := it.trim
      if line != "": line = " $line"
      fd.write "//$line\n"

  dump out-filename copyright-file -> none:
    fd := file.Stream.for-write out-filename
    copyright-lines.do:
      fd.write "// Copyright: $it\n"
    if copyright-file:
      dump-copyright-file copyright-file fd
    fd.write "\n"
    if comment-lines.size != 0:
      if doc-comments:
        fd.write "/**\n"
      comment-lines.do:
        fd.write "$(doc-comments ? "" : "// ")$it\n"
      if doc-comments:
        fd.write "*/\n"
      fd.write "\n"
    fd.write "/// Bitmaps for the $font-name font\n"
    fd.write "\n"
    short-filename := filename
    slash := short-filename.index-of --last "/"
    if slash != -1:
      short-filename = filename.copy slash + 1
    fd.write "// Autogenerated by convertfont.toit from the BDF file $short-filename\n"
    if bold:
      fd.write "// This font was automatically made bold by smearing the pixels horizontally\n"

    if (blocks.any: it.used and it.unicode-block.contains-icons):
      fd.write "\n"
      fd.write "import font show Font\n"
      fd.write "import icons show Icon\n"

    blocks.do: | block |
      if block.used
          and not block.unicode-block.abugida   // Exclude blocks that our font engine cannot support.
          and not block.unicode-block.vertical
          and not block.unicode-block.combining
          and not block.unicode-block.right-to-left:
        if bold: block.make-bold
        counter := LengthCounter block font-name copyright
        counter.dump

        block-size := counter.length

        fd.write "\n"
        if not block.unicode-block.contains-icons:
          write-block-intro_ fd block block-size
        name-bytes := ByteArray block.name.size
        name := block.all-caps-identifier
        if block.unicode-block.contains-icons:
          fd.write "$(name) ::= Font.from_page_ #[\n"
        else:
          fd.write "$(name) ::= #[\n"

        (CArrayDumper block counter).dump fd

        dump-char-names block fd

    fd.close

  write-block-intro_ fd block/Block block-size/int -> none:
    fd.write "/**\n"
    fd.write "The characters from the $block.name Unicode block in the $font-name font.\n"
    fd.write "  (See https://en.wikipedia.org/wiki/$block.unicode-block.wikipedia-name )\n"
    present-count := 0
    block.do: present-count++
    assigned := block.unicode-block.assigned
    if present-count >= assigned:
      fd.write "This block has $assigned assigned code points, and they are all\n"
      fd.write "  present in this font.\n"
    else:
      list-them := present-count <= 14
      snippet := present-count > assigned / 2 ? "and" : "but only"
      is-are := present-count == 1 ? "is" : "are"
      fd.write "This block has $assigned assigned code points, $snippet $present-count of\n"
      fd.write "  them $is-are present in this font$(list-them ? ":" : ".")\n"
      i := 0
      if list-them:
        block.do: | c code-point |
          i++
          ultimate := i == present-count
          penultimate := i == present-count - 1
          name := c.name
          if not name or name == "" or name.starts-with "uni":
            if COMMON-MISSING-CHAR-NAMES.contains code-point:
              name = COMMON-MISSING-CHAR-NAMES[code-point]
            else:
              name = "0x$(%04x code-point)"
          comma := ultimate ? "." : ","
          and-word := penultimate ? " and" : ""
          fd.write "  $name$comma$and-word\n"
    fd.write "  This block contains characters in the range 0x$(%04x block.from)-0x$(%04x block.to).\n"
    fd.write "  The bitmaps for this block in this font take up about $block-size bytes.\n"
    fd.write "*/\n"

  dump-char-names block/Block fd -> none:
    if not block.unicode-block.contains-icons: return

    block-identifier := block.all-caps-identifier

    fd.write "\n"
    block.do: | c/Char encoding/int |
      if c.name and c.name != "":
        // The Unicode standard requires that character names never include
        // non-ASCII, so we can do this without worrying about UTF-8.
        bytes := ByteArray c.name.size:
          name-char := c.name[it]
          if 'a' <= name-char <= 'z':
            name-char += 'A' - 'a'
          if (not 'A' <= name-char <= 'Z') and (not '0' <= name-char <= '9'):
            name-char = '-'
          name-char
        character-name := bytes.to-string
        if '0' <= character-name[0] <= '9':
          character-name = "_$character-name"
        fd.write "$character-name ::= Icon 0x$(%x encoding) $block-identifier\n"

    fd.write "\n"

abstract class DumperWithChecksum extends Dumper:
  constructor block/Block pass1:
    super block
    length = pass1.length
    checksum = pass1.checksum
    font-name = pass1.font-name
    copyright = pass1.copyright

class ListDumper extends DumperWithChecksum:
  bytes := []

  constructor block/Block pass1:
    super block pass1

  output-byte byte/int -> none:
    bytes.add byte

  output-hex-byte byte/int -> none:
    bytes.add byte

  output-char-constant byte/int -> none:
    bytes.add byte

  output-slash-slash-comment comment/string -> none:

  output-newline -> none:

  terminate -> none:
    bytes.add 0xff

class CArrayDumper extends DumperWithChecksum:
  fd_ := null

  dump fd:
    fd_ = fd
    dump

  current-line := "  "

  constructor block/Block pass1:
    super block pass1

  output-byte byte/int -> none:
    current-line += "$(byte & 0xff),"
    if verbose: current-line += " "

  output-hex-byte byte/int -> none:
    current-line += "0x$(%x byte & 0xff),"
    if verbose: current-line += " "

  output-char-constant byte/int -> none:
    if byte > 127: throw "Currently no support for UTF8 in font names"
    if 32 <= byte <= 126 and byte != '\\' and byte != '$' and byte != '\x27':
      // Printable and not dollar, single quote, or backslash.
      current-line += "'$(string.from-rune byte)',"
    else:
      current-line += "0x$(%02x byte & 0xff), "
    if byte == '\n' or (byte == ' ' and current-line.size > 60):
      output-newline

  output-slash-slash-comment comment/string -> none:
    if verbose:
      current-line += "// $comment"
    fd_.write "$current-line\n"
    current-line = "  "

  output-newline:
    fd_.write "$(current-line.trim --right)\n"
    current-line = "  "

  terminate -> none:
    fd_.write "$(current-line)0xff]\n"

class LengthCounter extends Dumper:
  bytes := []

  constructor block/Block font-name-argument/string copyright-argument/string:
    super block
    font-name = font-name-argument
    copyright = copyright-argument

  output-byte b/int -> none:
    bytes.add b
    length++

  output-hex-byte b/int -> none:
    bytes.add b
    length++

  output-char-constant b/int -> none:
    bytes.add b
    length++

  output-newline -> none:

  output-slash-slash-comment s/string -> none:

  reset-checksum:
    bytes = []

  terminate -> none:
    bytes.add 0xff
    length++
    byte-array := ByteArray bytes.size: bytes[it]
    checksum = sha256 byte-array

abstract class Dumper:
  constructor .block:

  block := ?
  length := 0
  checksum := ByteArray 32
  font-name := ""
  copyright := ""
  pending-sames_ := 0

  abstract output-byte byte/int -> none
  abstract output-hex-byte byte/int -> none
  abstract output-char-constant byte/int -> none
  abstract output-slash-slash-comment s/string -> none
  abstract output-newline -> none
  abstract terminate -> none
  reset-checksum:

  output-string key/int value/string -> none:
    output-char-constant -key
    value.do --runes: | rune |
      if rune == 0: throw "File format does not support strings with embedded nulls"
      output-char-constant rune
    output-byte 0

  output-integer key/int value/int -> none:
    output-byte key
    output-hex-byte value & 0xff
    output-hex-byte (value >> 8) & 0xff
    output-hex-byte (value >> 16) & 0xff

  dump-cardinal value:
    if value < 0x80:
      output-byte value
    else if value < 0x4000:
      output-byte (value >> 8) | 0x80
      output-byte value & 0xff
    else:
      output-byte (value >> 16) | 0xc0
      output-byte (value >> 8) & 0xff
      output-byte value & 0xff

  dump -> none:
    output-hex-byte 0x97
    output-hex-byte 0xf0
    output-hex-byte 0x17
    output-hex-byte 0x70
    output-slash-slash-comment "Magic number 0x7017f097."

    output-hex-byte length & 0xff
    output-hex-byte (length >> 8) & 0xff
    output-hex-byte (length >> 16) & 0xff
    output-hex-byte (length >> 24) & 0xff
    output-slash-slash-comment "Length $length."

    checksum.do: output-hex-byte it
    output-slash-slash-comment "Sha256 checksum."

    reset-checksum

    output-string 'n' font-name
    output-slash-slash-comment "Font name \"$font-name\"."

    output-string 'c' copyright
    output-slash-slash-comment "Copyright message"

    output-integer 'f' block.from
    output-slash-slash-comment "Unicode range start 0x$(%06x block.from)."

    output-integer 't' block.to
    output-slash-slash-comment "Unicode range end 0x$(%06x block.to)."

    output-byte 0
    output-newline

    (block.to + 1 - block.from).repeat: | j |
      c := block.chars[j]
      if c:
        encoding := block.from + j
        if (c.bits.every: it == 0):
          c.bbox.height = 0
          c.bits = ByteArray 0
        else:
          crop-bbox c
        output-byte c.width
        output-byte c.bbox.width
        output-byte c.bbox.height
        output-byte c.bbox.xoffset
        output-byte c.bbox.yoffset
        output-slash-slash-comment "$(%04x encoding) $c.name"
        if not COMPRESSING:
          dump-cardinal encoding
          dump-cardinal c.bits.size
          c.bits.do: output-byte it
        else:
          command-bits := []  // Pairs of bits that are commands to draw the glyph.
          emit-first-line c command-bits
          bytes-per-line := c.bytes-per-line_
          for k := bytes-per-line; k < c.bits.size; k += bytes-per-line:
            bytes-per-line.repeat: | l |
              m := k + l
              previous-byte ::= c.bits[m - bytes-per-line]
              new-byte := c.bits[m]
              emit-line command-bits previous-byte new-byte
          flush-sames command-bits
          dump-cardinal encoding
          byte-count := ((command-bits.size + 3) >> 2)
          dump-cardinal byte-count
          dump-command-bits command-bits
        output-newline
    terminate

  // Remove white space that is within the bounding box.  Good fonts don't have
  // this, but some hand-designed ones have.
  crop-bbox c/Char -> none:
    leading-blank-lines := 0
    trailing-blank-lines := 0
    bytes-per-line := c.bytes-per-line_
    for x := 0; x < c.bits.size; x++:
      if c.bits[x] != 0:
        leading-blank-lines = x / bytes-per-line
        break
    for x := c.bits.size - 1; x >= 0; x--:
      if c.bits[x] != 0:
        trailing-blank-lines = (c.bits.size - x - 1) / bytes-per-line
        break
    if leading-blank-lines != 0 or trailing-blank-lines != 0:
      c.bits = c.bits.copy
        leading-blank-lines * bytes-per-line
        c.bits.size - trailing-blank-lines * bytes-per-line
      c.bbox.height -= leading-blank-lines + trailing-blank-lines
      c.bbox.yoffset += trailing-blank-lines

  dump-command-bits command-bits/List -> none:
    for k := 0; k < command-bits.size; k += 4:
      b := command-bits[k] << 6
      b |= (k + 1 < command-bits.size) ? command-bits[k + 1] << 4 : 0
      b |= (k + 2 < command-bits.size) ? command-bits[k + 2] << 2 : 0
      b |= (k + 3 < command-bits.size) ? command-bits[k + 3] << 0 : 0
      if verbose:
        output-hex-byte b
      else:
        output-byte b

  flush-sames command-bits -> none:
    while pending-sames_ >= 10:
      chunk := min pending-sames_ 25
      pending-sames_ -= chunk
      chunk -= 10
      command-bits.add PREFIX-2
      command-bits.add PREFIX-2-3
      command-bits.add SAME-10-25
      command-bits.add chunk >> 2
      command-bits.add chunk & 3
    while pending-sames_ >= 4:
      chunk := min pending-sames_ 7
      pending-sames_ -= chunk
      chunk -= 4
      command-bits.add PREFIX-2
      command-bits.add SAME-4-7
      command-bits.add chunk
    while pending-sames_ >= 1:
      command-bits.add SAME-1
      pending-sames_--
    pending-sames_ = 0

  emit-first-line c/Char command-bits/List -> none:
    if c.bits.size > 0:
      bytes-per-line := c.bytes-per-line_
      // The first line has an all-zeros implied preceeding line, so it
      // is emitted a little differently.
      bytes-per-line.repeat: | k |
        new-bits := c.bits[k]
        if new-bits == 0:
          pending-sames_++
          continue.repeat
        flush-sames command-bits
        if new-bits == 0b1111_1111:
          command-bits.add PREFIX-3
          command-bits.add PREFIX-3-3
          command-bits.add ONES
        else if new-bits == 0x80:
          command-bits.add PREFIX-2
          command-bits.add PREFIX-2-3
          command-bits.add HI-BIT
        else if new-bits == 1:
          command-bits.add PREFIX-2
          command-bits.add PREFIX-2-3
          command-bits.add LO-BIT
        else:
          command-bits.add NEW
          command-bits.add (new-bits >> 6) & 3
          command-bits.add (new-bits >> 4) & 3
          command-bits.add (new-bits >> 2) & 3
          command-bits.add (new-bits >> 0) & 3

  emit-line command-bits/List previous-byte/int new-byte/int -> none:
    // The following lines are encoded relative to the line above them.
    left-shifted := (previous-byte << 1) & 0xff
    right-shifted := (previous-byte >> 1) & 0xff
    grow ::= previous-byte | left-shifted | right-shifted
    shrink ::= left-shifted & right-shifted
    left-grow ::= previous-byte | left-shifted
    right-grow ::= previous-byte | right-shifted
    left-shrink ::= previous-byte & right-shifted
    right-shrink ::= previous-byte & left-shifted
    if new-byte == previous-byte:
      pending-sames_++
      return
    flush-sames command-bits
    if new-byte == 0:
      command-bits.add PREFIX-3
      command-bits.add ZERO
    else if new-byte == left-grow:
      command-bits.add PREFIX-3
      command-bits.add GROW-LEFT
    else if new-byte == left-shifted:
      command-bits.add PREFIX-3
      command-bits.add LEFT
    else if new-byte == right-shifted:
      command-bits.add PREFIX-2
      command-bits.add RIGHT
    else if new-byte == right-grow:
      command-bits.add PREFIX-2
      command-bits.add GROW-RIGHT
    else if new-byte == left-shrink:
      command-bits.add PREFIX-3
      command-bits.add PREFIX-3-3
      command-bits.add SHRINK-LEFT
    else if new-byte == right-shrink:
      command-bits.add PREFIX-3
      command-bits.add PREFIX-3-3
      command-bits.add SHRINK-RIGHT
    else if new-byte == 0b1111_1111:
      command-bits.add PREFIX-3
      command-bits.add PREFIX-3-3
      command-bits.add ONES
    else if new-byte == grow:
      command-bits.add PREFIX-2
      command-bits.add PREFIX-2-3
      command-bits.add GROW
    else if new-byte == shrink:
      command-bits.add PREFIX-3
      command-bits.add PREFIX-3-3
      command-bits.add SHRINK
    else if new-byte == 0x80:
      command-bits.add PREFIX-2
      command-bits.add PREFIX-2-3
      command-bits.add HI-BIT
    else if new-byte == 1:
      command-bits.add PREFIX-2
      command-bits.add PREFIX-2-3
      command-bits.add LO-BIT
    else:
      command-bits.add NEW
      command-bits.add (new-byte >> 6) & 3
      command-bits.add (new-byte >> 4) & 3
      command-bits.add (new-byte >> 2) & 3
      command-bits.add (new-byte >> 0) & 3

  static NEW ::= 0          // 00         One literal byte of new pixel data follows.
  static SAME-1 ::= 1       // 01         Copy a byte directly from the line above.
  static PREFIX-2 ::= 2     // 10         Prefix.
  static SAME-4-7 ::= 0     // 10 00 xx     Copy 4-7 bytes.
  static GROW-RIGHT ::= 1   // 10 01        Copy one byte.
  static RIGHT ::= 2        // 10 10        Use the previous byte, shifted right one.
  static PREFIX-2-3 ::= 3   // 10 11        Prefix.
  static SAME-10-25 ::= 0   // 10 11 00 xx xx  Copy 10-25 bytes.
  static LO-BIT ::= 1       // 10 11 01       0x01
  static HI-BIT ::= 2       // 10 11 10       0x80
  static GROW ::= 3         // 10 11 11       Add one black pixel on each side
  static PREFIX-3 ::= 3     // 11         Prefix.
  static LEFT ::= 0         // 11 00        Use the previous byte, shifted left one.
  static GROW-LEFT ::= 1    // 11 01        Add one black pixel on the left of each run.
  static ZERO ::= 2         // 11 10        Use all-zero bits for this byte.
  static PREFIX-3-3 ::= 3   // 11 11        Prefix.
  static SHRINK-LEFT ::= 0  // 11 11 00       Remove one black pixel on the left of each run.
  static SHRINK-RIGHT ::= 1 // 11 11 01       Remove one black pixel on the right of each run.
  static SHRINK ::= 2       // 11 11 10       Remove one black pixel on each side.
  static ONES ::= 3         // 11 11 11       Use all-one bits for this byte.

UNICODE-BLOCKS := [
  UnicodeBlock "ASCII" 0x0000 0x007F --assigned=95 --wikipedia-name="Basic_Latin_(Unicode_block)",
  UnicodeBlock "Latin-1 Supplement" 0x0080 0x00FF --assigned=96 --disambiguate,
  UnicodeBlock "Latin Extended-A" 0x0100 0x017F,
  UnicodeBlock "Latin Extended-B" 0x0180 0x024F,
  UnicodeBlock "IPA Extensions" 0x0250 0x02AF,
  UnicodeBlock "Spacing Modifier Letters" 0x02B0 0x02FF,
  UnicodeBlock "Combining Diacritical Marks" 0x0300 0x036F --combining,
  UnicodeBlock "Greek and Coptic" 0x0370 0x03FF --assigned=135,
  UnicodeBlock "Cyrillic" 0x0400 0x04FF --disambiguate,
  UnicodeBlock "Cyrillic Supplement" 0x0500 0x052F,
  UnicodeBlock "Armenian" 0x0530 0x058F --assigned=91,
  UnicodeBlock "Hebrew" 0x0590 0x05FF --assigned=88 --right-to-left,
  UnicodeBlock "Arabic" 0x0600 0x06FF --assigned=255 --right-to-left,
  UnicodeBlock "Syriac" 0x0700 0x074F --assigned=77 --right-to-left,
  UnicodeBlock "Arabic Supplement" 0x0750 0x077F --right-to-left,
  UnicodeBlock "Thaana" 0x0780 0x07BF --assigned=50,
  UnicodeBlock "NKo" 0x07C0 0x07FF --assigned=62,
  UnicodeBlock "Samaritan" 0x0800 0x083F --assigned=61,
  UnicodeBlock "Mandaic" 0x0840 0x085F --assigned=29,
  UnicodeBlock "Syriac Supplement" 0x0860 0x086F --assigned=11 --right-to-left,
  UnicodeBlock "Arabic Extended-A" 0x08A0 0x08FF --assigned=84 --right-to-left,
  UnicodeBlock "Devanagari" 0x0900 0x097F --abugida,
  UnicodeBlock "Bengali" 0x0980 0x09FF --abugida --assigned=96,
  UnicodeBlock "Gurmukhi" 0x0A00 0x0A7F --abugida --assigned=80,
  UnicodeBlock "Gujarati" 0x0A80 0x0AFF --abugida --assigned=91,
  UnicodeBlock "Oriya" 0x0B00 0x0B7F --abugida --assigned=91,
  UnicodeBlock "Tamil" 0x0B80 0x0BFF --abugida --assigned=72,
  UnicodeBlock "Telugu" 0x0C00 0x0C7F --abugida --assigned=98,
  UnicodeBlock "Kannada" 0x0C80 0x0CFF --abugida --assigned=89,
  UnicodeBlock "Malayalam" 0x0D00 0x0D7F --abugida --assigned=118,
  UnicodeBlock "Sinhala" 0x0D80 0x0DFF --abugida --assigned=91,
  UnicodeBlock "Thai" 0x0E00 0x0E7F --abugida --assigned=87,
  UnicodeBlock "Lao" 0x0E80 0x0EFF --abugida --assigned=82,
  UnicodeBlock "Tibetan" 0x0F00 0x0FFF --abugida --assigned=211,
  UnicodeBlock "Myanmar" 0x1000 0x109F --abugida,
  UnicodeBlock "Georgian" 0x10A0 0x10FF --assigned=88,
  UnicodeBlock "Hangul Jamo" 0x1100 0x11FF --disambiguate,
  UnicodeBlock "Ethiopic" 0x1200 0x137F --assigned=358,
  UnicodeBlock "Ethiopic Supplement" 0x1380 0x139F --assigned=26,
  UnicodeBlock "Cherokee" 0x13A0 0x13FF --assigned=92,
  UnicodeBlock "Unified Canadian Aboriginal Syllabics" 0x1400 0x167F --disambiguate,
  UnicodeBlock "Ogham" 0x1680 0x169F --assigned=29,
  UnicodeBlock "Runic" 0x16A0 0x16FF --assigned=89,
  UnicodeBlock "Tagalog" 0x1700 0x171F --assigned=20,
  UnicodeBlock "Hanunoo" 0x1720 0x173F --abugida --assigned=23,
  UnicodeBlock "Buhid" 0x1740 0x175F --abugida --assigned=20,
  UnicodeBlock "Tagbanwa" 0x1760 0x177F --abugida --assigned=18,
  UnicodeBlock "Khmer" 0x1780 0x17FF --abugida --assigned=114,
  UnicodeBlock "Mongolian" 0x1800 0x18AF --assigned=157,
  UnicodeBlock "Unified Canadian Aboriginal Syllabics Extended" 0x18B0 0x18FF --assigned=70,
  UnicodeBlock "Limbu" 0x1900 0x194F --abugida --assigned=68,
  UnicodeBlock "Tai Le" 0x1950 0x197F --abugida --assigned=35 --disambiguate,
  UnicodeBlock "New Tai Lue" 0x1980 0x19DF --abugida --assigned=83 --disambiguate,
  UnicodeBlock "Khmer Symbols" 0x19E0 0x19FF,
  UnicodeBlock "Buginese" 0x1A00 0x1A1F --abugida --assigned=30,
  UnicodeBlock "Tai Tham" 0x1A20 0x1AAF --abugida --assigned=127 --disambiguate,
  UnicodeBlock "Combining Diacritical Marks Extended" 0x1AB0 0x1AFF --combining --assigned=17,
  UnicodeBlock "Balinese" 0x1B00 0x1B7F --abugida --assigned=121,
  UnicodeBlock "Sundanese" 0x1B80 0x1BBF --abugida,
  UnicodeBlock "Batak" 0x1BC0 0x1BFF --abugida --assigned=56,
  UnicodeBlock "Lepcha" 0x1C00 0x1C4F --abugida --assigned=74,
  UnicodeBlock "Ol Chiki" 0x1C50 0x1C7F --disambiguate,
  UnicodeBlock "Cyrillic Extended-C" 0x1C80 0x1C8F --assigned=9,
  UnicodeBlock "Georgian Extended" 0x1C90 0x1CBF --assigned=46,
  UnicodeBlock "Sundanese Supplement" 0x1CC0 0x1CCF --abugida --assigned=8,
  UnicodeBlock "Vedic Extensions" 0x1CD0 0x1CFF --abugida --assigned=43,
  UnicodeBlock "Phonetic Extensions" 0x1D00 0x1D7F,
  UnicodeBlock "Phonetic Extensions Supplement" 0x1D80 0x1DBF,
  UnicodeBlock "Combining Diacritical Marks Supplement" 0x1DC0 0x1DFF --combining --assigned=63,
  UnicodeBlock "Latin Extended Additional" 0x1E00 0x1EFF,
  UnicodeBlock "Greek Extended" 0x1F00 0x1FFF --assigned=233,
  UnicodeBlock "General Punctuation" 0x2000 0x206F --assigned=111,
  UnicodeBlock "Superscripts and Subscripts" 0x2070 0x209F --assigned=42 --disambiguate,
  UnicodeBlock "Currency Symbols" 0x20A0 0x20CF --assigned=32 --disambiguate,
  UnicodeBlock "Combining Diacritical Marks for Symbols" 0x20D0 0x20FF --combining --assigned=33,
  UnicodeBlock "Letterlike Symbols" 0x2100 0x214F,
  UnicodeBlock "Number Forms" 0x2150 0x218F --assigned=60,
  UnicodeBlock "Arrows" 0x2190 0x21FF --disambiguate,
  UnicodeBlock "Mathematical Operators" 0x2200 0x22FF,
  UnicodeBlock "Miscellaneous Technical" 0x2300 0x23FF,
  UnicodeBlock "Control Pictures" 0x2400 0x243F --assigned=39,
  UnicodeBlock "Optical Character Recognition" 0x2440 0x245F --assigned=11 --disambiguate,
  UnicodeBlock "Enclosed Alphanumerics" 0x2460 0x24FF,
  UnicodeBlock "Box Drawing" 0x2500 0x257F --disambiguate,
  UnicodeBlock "Block Elements" 0x2580 0x259F,
  UnicodeBlock "Geometric Shapes" 0x25A0 0x25FF,
  UnicodeBlock "Miscellaneous Symbols" 0x2600 0x26FF,
  UnicodeBlock "Dingbats" 0x2700 0x27BF --wikipedia-name="Dingbat#Unicode",
  UnicodeBlock "Miscellaneous Mathematical Symbols-A" 0x27C0 0x27EF,
  UnicodeBlock "Supplemental Arrows-A" 0x27F0 0x27FF,
  UnicodeBlock "Braille Patterns" 0x2800 0x28FF,
  UnicodeBlock "Supplemental Arrows-B" 0x2900 0x297F,
  UnicodeBlock "Miscellaneous Mathematical Symbols-B" 0x2980 0x29FF,
  UnicodeBlock "Supplemental Mathematical Operators" 0x2A00 0x2AFF,
  UnicodeBlock "Miscellaneous Symbols and Arrows" 0x2B00 0x2BFF --assigned=253,
  UnicodeBlock "Glagolitic" 0x2C00 0x2C5F --assigned=94,
  UnicodeBlock "Latin Extended-C" 0x2C60 0x2C7F,
  UnicodeBlock "Coptic" 0x2C80 0x2CFF --assigned=123,
  UnicodeBlock "Georgian Supplement" 0x2D00 0x2D2F --assigned=40,
  UnicodeBlock "Tifinagh" 0x2D30 0x2D7F --assigned=59,
  UnicodeBlock "Ethiopic Extended" 0x2D80 0x2DDF --assigned=79,
  UnicodeBlock "Cyrillic Extended-A" 0x2DE0 0x2DFF,
  UnicodeBlock "Supplemental Punctuation" 0x2E00 0x2E7F --assigned=83,
  UnicodeBlock "CJK Radicals Supplement" 0x2E80 0x2EFF --assigned=115,
  UnicodeBlock "Kangxi Radicals" 0x2F00 0x2FDF --assigned=214 --wikipedia-name="Kangxi_radical#Unicode",
  UnicodeBlock "Ideographic Description Characters" 0x2FF0 0x2FFF --assigned=12 --disambiguate,
  UnicodeBlock "CJK Symbols and Punctuation" 0x3000 0x303F,
  UnicodeBlock "Hiragana" 0x3040 0x309F --assigned=93,
  UnicodeBlock "Katakana" 0x30A0 0x30FF,
  UnicodeBlock "Bopomofo" 0x3100 0x312F --assigned=43,
  UnicodeBlock "Hangul Compatibility Jamo" 0x3130 0x318F --assigned=94,
  UnicodeBlock "Kanbun" 0x3190 0x319F,
  UnicodeBlock "Bopomofo Extended" 0x31A0 0x31BF,
  UnicodeBlock "CJK Strokes" 0x31C0 0x31EF --assigned=36 --disambiguate,
  UnicodeBlock "Katakana Phonetic Extensions" 0x31F0 0x31FF,
  UnicodeBlock "Enclosed CJK Letters and Months" 0x3200 0x32FF --assigned=255,
  UnicodeBlock "CJK Compatibility" 0x3300 0x33FF,
  UnicodeBlock "CJK Unified Ideographs Extension A" 0x3400 0x4DBF,
  UnicodeBlock "Yijing Hexagram Symbols" 0x4DC0 0x4DFF --disambiguate,
  UnicodeBlock "CJK Unified Ideographs" 0x4E00 0x9FFF --assigned=20989 --disambiguate,
  UnicodeBlock "Yi Syllables" 0xA000 0xA48F --assigned=1165,
  UnicodeBlock "Yi Radicals" 0xA490 0xA4CF --assigned=55,
  UnicodeBlock "Lisu" 0xA4D0 0xA4FF,
  UnicodeBlock "Vai" 0xA500 0xA63F --assigned=300,
  UnicodeBlock "Cyrillic Extended-B" 0xA640 0xA69F,
  UnicodeBlock "Bamum" 0xA6A0 0xA6FF --assigned=88,
  UnicodeBlock "Modifier Tone Letters" 0xA700 0xA71F,
  UnicodeBlock "Latin Extended-D" 0xA720 0xA7FF --assigned=180,
  UnicodeBlock "Syloti Nagri" 0xA800 0xA82F --assigned=45 --disambiguate,
  UnicodeBlock "Common Indic Number Forms" 0xA830 0xA83F --assigned=10,
  UnicodeBlock "Phags-pa" 0xA840 0xA87F --abugida --assigned=56,
  UnicodeBlock "Saurashtra" 0xA880 0xA8DF --abugida --assigned=82,
  UnicodeBlock "Devanagari Extended" 0xA8E0 0xA8FF --abugida,
  UnicodeBlock "Kayah Li" 0xA900 0xA92F --abugida --disambiguate,
  UnicodeBlock "Rejang" 0xA930 0xA95F --abugida --assigned=37,
  UnicodeBlock "Hangul Jamo Extended-A" 0xA960 0xA97F --assigned=29,
  UnicodeBlock "Javanese" 0xA980 0xA9DF --abugida --assigned=91,
  UnicodeBlock "Myanmar Extended-B" 0xA9E0 0xA9FF --abugida --assigned=31,
  UnicodeBlock "Cham" 0xAA00 0xAA5F --abugida --assigned=83,
  UnicodeBlock "Myanmar Extended-A" 0xAA60 0xAA7F --abugida,
  UnicodeBlock "Tai Viet" 0xAA80 0xAADF --abugida --assigned=72 --disambiguate,
  UnicodeBlock "Meetei Mayek Extensions" 0xAAE0 0xAAFF --abugida --assigned=23 --disambiguate,
  UnicodeBlock "Ethiopic Extended-A" 0xAB00 0xAB2F --assigned=32,
  UnicodeBlock "Latin Extended-E" 0xAB30 0xAB6F --assigned=60,
  UnicodeBlock "Cherokee Supplement" 0xAB70 0xABBF,
  UnicodeBlock "Meetei Mayek" 0xABC0 0xABFF --abugida --assigned=56 --disambiguate,
  UnicodeBlock "Hangul Syllables" 0xAC00 0xD7AF --assigned=11172,
  UnicodeBlock "Hangul Jamo Extended-B" 0xD7B0 0xD7FF --assigned=72,
  UnicodeBlock "High Surrogates" 0xD800 0xDB7F --wikipedia-name="Universal_Character_Set_characters#Surrogates",
  UnicodeBlock "High Private Use Surrogates" 0xDB80 0xDBFF --wikipedia-name="Universal_Character_Set_characters#Surrogates",
  UnicodeBlock "Low Surrogates" 0xDC00 0xDFFF --wikipedia-name="Universal_Character_Set_characters#Surrogates",
  UnicodeBlock "Private Use Area" 0xE000 0xF8FF,
  UnicodeBlock "CJK Compatibility Ideographs" 0xF900 0xFAFF --assigned=472,
  UnicodeBlock "Alphabetic Presentation Forms" 0xFB00 0xFB4F --assigned=58,
  UnicodeBlock "Arabic Presentation Forms-A" 0xFB50 0xFDFF --assigned=611 --right-to-left,
  UnicodeBlock "Variation Selectors" 0xFE00 0xFE0F --disambiguate,
  UnicodeBlock "Vertical Forms" 0xFE10 0xFE1F --assigned=10,
  UnicodeBlock "Combining Half Marks" 0xFE20 0xFE2F --combining,
  UnicodeBlock "CJK Compatibility Forms" 0xFE30 0xFE4F,
  UnicodeBlock "Small Form Variants" 0xFE50 0xFE6F --assigned=26,
  // This is right-to-left, but we don't mark it as such because it contains
  // the possibly useful zero width no-break space character.
  UnicodeBlock "Arabic Presentation Forms-B" 0xFE70 0xFEFF --assigned=141,
  UnicodeBlock "Halfwidth and Fullwidth Forms" 0xFF00 0xFFEF --assigned=225 --disambiguate,
  UnicodeBlock "Specials" 0xFFF0 0xFFFF --assigned=5,
  UnicodeBlock "Linear B Syllabary" 0x10000 0x1007F --assigned=88,
  UnicodeBlock "Linear B Ideograms" 0x10080 0x100FF --assigned=123,
  UnicodeBlock "Aegean Numbers" 0x10100 0x1013F --assigned=57 --disambiguate,
  UnicodeBlock "Ancient Greek Numbers" 0x10140 0x1018F --assigned=79 --disambiguate,
  UnicodeBlock "Ancient Symbols" 0x10190 0x101CF --assigned=14 --disambiguate,
  UnicodeBlock "Phaistos Disc" 0x101D0 0x101FF --assigned=46 --disambiguate,
  UnicodeBlock "Lycian" 0x10280 0x1029F --assigned=29,
  UnicodeBlock "Carian" 0x102A0 0x102DF --assigned=49,
  UnicodeBlock "Coptic Epact Numbers" 0x102E0 0x102FF --assigned=28,
  UnicodeBlock "Old Italic" 0x10300 0x1032F --assigned=39 --disambiguate,
  UnicodeBlock "Gothic" 0x10330 0x1034F --assigned=27,
  UnicodeBlock "Old Permic" 0x10350 0x1037F --assigned=43 --disambiguate,
  UnicodeBlock "Ugaritic" 0x10380 0x1039F --assigned=31,
  UnicodeBlock "Old Persian" 0x103A0 0x103DF --assigned=50 --disambiguate --right-to-left,
  UnicodeBlock "Deseret" 0x10400 0x1044F,
  UnicodeBlock "Shavian" 0x10450 0x1047F,
  UnicodeBlock "Osmanya" 0x10480 0x104AF --assigned=40,
  UnicodeBlock "Osage" 0x104B0 0x104FF --assigned=72,
  UnicodeBlock "Elbasan" 0x10500 0x1052F --assigned=40,
  UnicodeBlock "Caucasian Albanian" 0x10530 0x1056F --assigned=53 --disambiguate,
  UnicodeBlock "Linear A" 0x10600 0x1077F --assigned=341 --disambiguate,
  UnicodeBlock "Cypriot Syllabary" 0x10800 0x1083F --assigned=55 --disambiguate,
  UnicodeBlock "Imperial Aramaic" 0x10840 0x1085F --assigned=31 --disambiguate,
  UnicodeBlock "Palmyrene" 0x10860 0x1087F --right-to-left,
  UnicodeBlock "Nabataean" 0x10880 0x108AF --assigned=40 --right-to-left,
  UnicodeBlock "Hatran" 0x108E0 0x108FF --assigned=26 --right-to-left,
  UnicodeBlock "Phoenician" 0x10900 0x1091F --assigned=29 --right-to-left,
  UnicodeBlock "Lydian" 0x10920 0x1093F --assigned=27 --right-to-left,
  UnicodeBlock "Meroitic Hieroglyphs" 0x10980 0x1099F --disambiguate,
  UnicodeBlock "Meroitic Cursive" 0x109A0 0x109FF --assigned=90 --disambiguate,
  UnicodeBlock "Kharoshthi" 0x10A00 0x10A5F --assigned=68 --right-to-left,
  UnicodeBlock "Old South Arabian" 0x10A60 0x10A7F --right-to-left,
  UnicodeBlock "Old North Arabian" 0x10A80 0x10A9F --right-to-left,
  UnicodeBlock "Manichaean" 0x10AC0 0x10AFF --assigned=51 --right-to-left,
  UnicodeBlock "Avestan" 0x10B00 0x10B3F --assigned=61 --right-to-left,
  UnicodeBlock "Inscriptional Parthian" 0x10B40 0x10B5F --assigned=30 --disambiguate --right-to-left,
  UnicodeBlock "Inscriptional Pahlavi" 0x10B60 0x10B7F --assigned=27 --disambiguate --right-to-left,
  UnicodeBlock "Psalter Pahlavi" 0x10B80 0x10BAF --assigned=29 --disambiguate --right-to-left,
  UnicodeBlock "Old Turkic" 0x10C00 0x10C4F --assigned=73 --disambiguate --right-to-left,
  UnicodeBlock "Old Hungarian" 0x10C80 0x10CFF --assigned=108 --disambiguate --right-to-left,
  UnicodeBlock "Hanifi Rohingya" 0x10D00 0x10D3F --assigned=50 --disambiguate --right-to-left,
  UnicodeBlock "Rumi Numeral Symbols" 0x10E60 0x10E7F --assigned=31,
  UnicodeBlock "Yezidi" 0x10E80 0x10EBF --assigned=47 --right-to-left,
  UnicodeBlock "Old Sogdian" 0x10F00 0x10F2F --assigned=40 --disambiguate,
  UnicodeBlock "Sogdian" 0x10F30 0x10F6F --assigned=42 --right-to-left,
  UnicodeBlock "Brahmi" 0x11000 0x1107F --assigned=109 --abugida,
  UnicodeBlock "Kaithi" 0x11080 0x110CF --assigned=67 --abugida,
  UnicodeBlock "Sora Sompeng" 0x110D0 0x110FF --assigned=35 --disambiguate,
  UnicodeBlock "Chakma" 0x11100 0x1114F --assigned=71 --abugida,
  UnicodeBlock "Mahajani" 0x11150 0x1117F --assigned=39,
  UnicodeBlock "Sharada" 0x11180 0x111DF --abugida,
  UnicodeBlock "Sinhala Archaic Numbers" 0x111E0 0x111FF --assigned=20,
  UnicodeBlock "Khojki" 0x11200 0x1124F --abugida --assigned=62,
  UnicodeBlock "Multani" 0x11280 0x112AF --abugida --assigned=38,
  UnicodeBlock "Khudawadi" 0x112B0 0x112FF --abugida --assigned=69,
  UnicodeBlock "Grantha" 0x11300 0x1137F --abugida --assigned=86,
  UnicodeBlock "Newa" 0x11400 0x1147F --abugida --assigned=97,
  UnicodeBlock "Tirhuta" 0x11480 0x114DF --abugida --assigned=82,
  UnicodeBlock "Siddham" 0x11580 0x115FF --abugida --assigned=92,
  UnicodeBlock "Modi" 0x11600 0x1165F --abugida --assigned=79,
  UnicodeBlock "Mongolian Supplement" 0x11660 0x1167F --vertical --assigned=13,
  UnicodeBlock "Takri" 0x11680 0x116CF --abugida --assigned=67,
  UnicodeBlock "Ahom" 0x11700 0x1173F --abugida --assigned=58,
  UnicodeBlock "Dogra" 0x11800 0x1184F --abugida --assigned=60,
  UnicodeBlock "Warang Citi" 0x118A0 0x118FF --assigned=84 --disambiguate,
  UnicodeBlock "Dives Akuru" 0x11900 0x1195F --abugida --assigned=72,
  UnicodeBlock "Zanabazar Square" 0x11A00 0x11A4F --abugida --assigned=65 --disambiguate,
  UnicodeBlock "Soyombo" 0x11A50 0x11AAF --abugida --assigned=72,
  UnicodeBlock "Pau Cin Hau" 0x11AC0 0x11AFF --assigned=57 --disambiguate,
  UnicodeBlock "Bhaiksuki" 0x11C00 0x11C6F --abugida --assigned=97,
  UnicodeBlock "Marchen" 0x11C70 0x11CBF --assigned=68,
  UnicodeBlock "Masaram Gondi" 0x11D00 0x11D5F --abugida --assigned=75 --disambiguate,
  UnicodeBlock "Gunjala Gondi" 0x11D60 0x11DAF --abugida --assigned=63 --disambiguate,
  UnicodeBlock "Makasar" 0x11EE0 0x11EFF --abugida --assigned=25,
  UnicodeBlock "Lisu Supplement" 0x11FB0 0x11FBF --assigned=1,
  UnicodeBlock "Tamil Supplement" 0x11FC0 0x11FFF --abugida --assigned=51,
  UnicodeBlock "Cuneiform" 0x12000 0x123FF --assigned=922,
  UnicodeBlock "Cuneiform Numbers and Punctuation" 0x12400 0x1247F --assigned=116,
  UnicodeBlock "Early Dynastic Cuneiform" 0x12480 0x1254F --assigned=196,
  UnicodeBlock "Egyptian Hieroglyphs" 0x13000 0x1342F --assigned=1071 --disambiguate,
  UnicodeBlock "Anatolian Hieroglyphs" 0x14400 0x1467F --assigned=583 --disambiguate,
  UnicodeBlock "Bamum Supplement" 0x16800 0x16A3F --assigned=569,
  UnicodeBlock "Mro" 0x16A40 0x16A6F --assigned=43,
  UnicodeBlock "Bassa Vah" 0x16AD0 0x16AFF --assigned=36 --disambiguate,
  // Technically not an abugida, but has the same issues for us.
  UnicodeBlock "Pahawh Hmong" 0x16B00 0x16B8F --abugida --assigned=127 --disambiguate,
  UnicodeBlock "Medefaidrin" 0x16E40 0x16E9F --assigned=91,
  UnicodeBlock "Miao" 0x16F00 0x16F9F --abugida --assigned=149,
  UnicodeBlock "Ideographic Symbols and Punctuation" 0x16FE0 0x16FFF --assigned=7,
  UnicodeBlock "Tangut" 0x17000 0x187FF --vertical --assigned=6136,
  UnicodeBlock "Tangut Components" 0x18800 0x18AFF --vertical,
  UnicodeBlock "Khitan Small Script" 0x18B00 0x18CFF --vertical --assigned=470 --disambiguate,
  UnicodeBlock "Tangut Supplement" 0x18D00 0x18D8F --vertical --assigned=9,
  UnicodeBlock "Kana Supplement" 0x1B000 0x1B0FF,
  UnicodeBlock "Kana Extended-A" 0x1B100 0x1B12F --assigned=31,
  UnicodeBlock "Small Kana Extension" 0x1B130 0x1B16F --assigned=7,
  UnicodeBlock "Nushu" 0x1B170 0x1B2FF --assigned=396,
  UnicodeBlock "Duployan" 0x1BC00 0x1BC9F --assigned=143,
  UnicodeBlock "Shorthand Format Controls" 0x1BCA0 0x1BCAF --assigned=4,
  UnicodeBlock "Byzantine Musical Symbols" 0x1D000 0x1D0FF --assigned=246,
  UnicodeBlock "Musical Symbols" 0x1D100 0x1D1FF --assigned=231 --disambiguate,
  UnicodeBlock "Ancient Greek Musical Notation" --assigned=70 0x1D200 0x1D24F,
  UnicodeBlock "Mayan Numerals" 0x1D2E0 0x1D2FF --assigned=20 --disambiguate,
  UnicodeBlock "Tai Xuan Jing Symbols" 0x1D300 0x1D35F --assigned=87 --wikipedia-name="Taixuanjing",
  UnicodeBlock "Counting Rod Numerals" 0x1D360 0x1D37F --assigned=25 --disambiguate,
  UnicodeBlock "Mathematical Alphanumeric Symbols" 0x1D400 0x1D7FF --assigned=996,
  UnicodeBlock "Sutton SignWriting" 0x1D800 0x1DAAF --assigned=672 --disambiguate,
  UnicodeBlock "Glagolitic Supplement" 0x1E000 0x1E02F --assigned=38,
  UnicodeBlock "Nyiakeng Puachue Hmong" 0x1E100 0x1E14F --assigned=71 --disambiguate,
  UnicodeBlock "Mende Kikakui" 0x1E800 0x1E8DF --assigned=213 --disambiguate,
  UnicodeBlock "Adlam" 0x1E900 0x1E95F --assigned=88 --right-to-left,
  UnicodeBlock "Indic Siyaq Numbers" 0x1EC70 0x1ECBF --assigned=68 --disambiguate,
  UnicodeBlock "Ottoman Siyaq Numbers" 0x1ED00 0x1ED4F --assigned=61 --disambiguate,
  UnicodeBlock "Arabic Mathematical Alphabetic Symbols" 0x1EE00 0x1EEFF --assigned=143,
  UnicodeBlock "Mahjong Tiles" 0x1F000 0x1F02F --assigned=44 --disambiguate,
  UnicodeBlock "Domino Tiles" 0x1F030 0x1F09F --assigned=100,
  UnicodeBlock "Playing Cards" 0x1F0A0 0x1F0FF --assigned=82 --wikipedia-name="Playing_cards_in_Unicode",
  UnicodeBlock "Enclosed Alphanumeric Supplement" 0x1F100 0x1F1FF --assigned=200,
  UnicodeBlock "Enclosed Ideographic Supplement" 0x1F200 0x1F2FF --assigned=64,
  UnicodeBlock "Miscellaneous Symbols and Pictographs" 0x1F300 0x1F5FF,
  UnicodeBlock "Emoticons" 0x1F600 0x1F64F,
  UnicodeBlock "Ornamental Dingbats" 0x1F650 0x1F67F,
  UnicodeBlock "Transport and Map Symbols" 0x1F680 0x1F6FF --assigned=114,
  UnicodeBlock "Alchemical Symbols" 0x1F700 0x1F77F --disambiguate --assigned=116,
  UnicodeBlock "Geometric Shapes Extended" 0x1F780 0x1F7FF --assigned=101,
  UnicodeBlock "Supplemental Arrows-C" 0x1F800 0x1F8FF --assigned=150,
  UnicodeBlock "Supplemental Symbols and Pictographs" 0x1F900 0x1F9FF --assigned=254,
  UnicodeBlock "Chess Symbols" 0x1FA00 0x1FA6F --assigned=98,
  UnicodeBlock "CJK Unified Ideographs Extension B" 0x20000 0x2A6DF --assigned=42718,
  UnicodeBlock "CJK Unified Ideographs Extension C" 0x2A700 0x2B73F --assigned=4149,
  UnicodeBlock "CJK Unified Ideographs Extension D" 0x2B740 0x2B81F --assigned=222,
  UnicodeBlock "CJK Unified Ideographs Extension E" 0x2B820 0x2CEAF --assigned=5762,
  UnicodeBlock "CJK Unified Ideographs Extension F" 0x2CEB0 0x2EBEF --assigned=7473,
  UnicodeBlock "CJK Compatibility Ideographs Supplement" 0x2F800 0x2FA1F --assigned=542,
  UnicodeBlock "CJK Unified Ideographs Extension G" 0x30000 0x3134F --assigned=4939,
  UnicodeBlock "Tags" 0xE0000 0xE007F --assigned=97,
  UnicodeBlock "Variation Selectors Supplement" 0xE0100 0xE01EF,
]

COMMON-MISSING-CHAR-NAMES ::= {
  0x259: "latin small letter schwa (ə)",
  0x2bc: "modifier letter apostrophe",
  0x2c9: "modifier letter macron",
  0x2f3: "modifier letter low ring",
  0x30f: "doublegravecomb",
  0x37e: "Greek question mark (;)",
  0x1f4d: "Greek capital letter omicron with dasia and oxia (Ὅ)",
  0x2047: "double question mark (⁇)",
  0x2074: "superscript 4",
  0x207f: "superscript latin small letter n",
  0x20a5: "Mill",
  0x20a6: "Naira",
  0x20a9: "Won",
  0x20a8: "Rupee",
  0x20aa: "New Sheqel",
  0x20ad: "Kip",
  0x20b1: "Peso",
  0x20b9: "Indian Rupee",
  0x20ba: "Turkish Lira",
  0x20bc: "Manat",
  0x20bd: "Ruble",
  0x2103: "degree Celcius",
  0x2105: "care of",
  0x2109: "degree Fahrenheit",
  0x2113: "script small l",
  0x2116: "numero sign (№)",
  0x212a: "Kelvin sign",
  0x212b: "Angstrom sign",
  0x2132: "turned capital F",
  0xfb01: "latin small ligature fi",
  0xfb02: "latin small ligature fl",
  0xfb03: "latin small ligature ffi",
  0xfb04: "latin small ligature ffl",
  0xfeff: "zero width no-break space",
  0xfffc: "object replacement character ￼",
  0xfffd: "replacement character �",
}
